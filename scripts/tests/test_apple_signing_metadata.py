import copy
import datetime as dt
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("signing_metadata", ROOT / "scripts/ci/check_apple_signing_metadata.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class SigningMetadataTests(unittest.TestCase):
    def setUp(self):
        self.now = dt.datetime(2026, 10, 2, tzinfo=dt.timezone.utc)
        self.contract = MODULE.PROFILES["APP_STORE_PROFILE_IOS_WIDGET"]
        self.cert = b"public certificate fixture"
        self.digest = MODULE.hashlib.sha256(self.cert).digest()
        self.profile = {
            "CreationDate": self.now - dt.timedelta(days=1),
            "ExpirationDate": self.now + dt.timedelta(days=1),
            "Platform": ["iOS"], "TeamIdentifier": ["FIXTURE_TEAM"],
            "DeveloperCertificates": [self.cert],
            "Entitlements": {"application-identifier": "FIXTURE_TEAM.io.ethan.pushgo.widgets", "get-task-allow": False, "aps-environment": "production", "com.apple.security.application-groups": ["group.ethan.pushgo.messages"]},
        }
        self.entitlements = {"aps-environment": "development", "com.apple.security.application-groups": ["group.ethan.pushgo.messages"]}

    def check(self, profile, digest=None):
        return MODULE.profile_checks(profile, self.contract, "FIXTURE_TEAM", digest or self.digest, self.now, self.entitlements)

    def test_current_store_profile_matches_the_reachable_widget_contract(self):
        self.assertTrue(all(self.check(self.profile).values()))

    def test_development_and_ad_hoc_profiles_cannot_pass_store_distribution(self):
        for field, value in [("ProvisionedDevices", ["fixture-device"]), ("ProvisionsAllDevices", True)]:
            profile = copy.deepcopy(self.profile)
            profile[field] = value
            self.assertFalse(self.check(profile)["distribution_matches"])
        profile = copy.deepcopy(self.profile)
        profile["Entitlements"]["get-task-allow"] = True
        self.assertFalse(self.check(profile)["distribution_matches"])

    def test_expired_profile_and_wrong_certificate_are_rejected(self):
        profile = copy.deepcopy(self.profile)
        profile["ExpirationDate"] = self.now
        self.assertFalse(self.check(profile)["currently_valid"])
        self.assertFalse(self.check(self.profile, b"different certificate digest")["certificate_matches"])

    def test_mac_direct_distribution_allows_absent_debug_entitlement_but_rejects_debugging(self):
        contract = MODULE.PROFILES["DEVELOPER_ID_PROFILE_MACOS_WIDGET"]
        profile = copy.deepcopy(self.profile)
        profile["Platform"] = ["OSX"]
        profile["ProvisionsAllDevices"] = True
        granted = profile["Entitlements"]
        granted["application-identifier"] = "FIXTURE_TEAM." + contract[0]
        del granted["get-task-allow"]
        def check():
            return MODULE.profile_checks(profile, contract, "FIXTURE_TEAM", self.digest, self.now, self.entitlements)
        self.assertTrue(all(check().values()))
        for key in ["get-task-allow", "com.apple.security.get-task-allow"]:
            granted[key] = True
            self.assertFalse(check()["distribution_matches"])
            del granted[key]
        profile["ProvisionedDevices"] = ["fixture-device"]
        self.assertFalse(check()["distribution_matches"])
        del profile["ProvisionedDevices"]
        profile["ProvisionsAllDevices"] = False
        self.assertFalse(check()["distribution_matches"])

    def test_missing_ios_debugging_restriction_is_rejected(self):
        profile = copy.deepcopy(self.profile)
        del profile["Entitlements"]["get-task-allow"]
        self.assertFalse(self.check(profile)["distribution_matches"])

    def test_wrong_bundle_team_group_or_push_environment_cannot_pass(self):
        mutations = [("application-identifier", "FIXTURE_TEAM.wrong.widget", "bundle_matches"), ("com.apple.security.application-groups", [], "app_groups_match"), ("aps-environment", "development", "production_push_matches")]
        for key, value, expected in mutations:
            profile = copy.deepcopy(self.profile)
            profile["Entitlements"][key] = value
            self.assertFalse(self.check(profile)[expected])
        profile = copy.deepcopy(self.profile)
        profile["TeamIdentifier"] = ["WRONG_TEAM"]
        self.assertFalse(self.check(profile)["team_matches"])

    def test_decoder_error_never_exports_raw_material_or_exception_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "verdict.json"
            captured = io.StringIO()
            with patch.dict(os.environ, {"APPLE_TEAM_ID": "FIXTURE_TEAM"}, clear=True), patch.object(MODULE, "certificate_metadata", side_effect=ValueError("PRIVATE_SENTINEL")), patch("sys.argv", ["metadata", "--output", str(output)]), patch("sys.stdout", captured):
                self.assertEqual(MODULE.main(), 2)
            report = output.read_text()
            self.assertNotIn("PRIVATE_SENTINEL", report + captured.getvalue())
            self.assertNotIn("FIXTURE_TEAM", report + captured.getvalue())
            self.assertEqual(json.loads(report)["actual_signing"], "NOT_RUN")

    def test_workflow_consumes_exact_secret_names_only_at_the_metadata_step(self):
        workflow = (ROOT / ".github/workflows/apple-signing-preflight.yml").read_text()
        for name in MODULE.CERTIFICATES:
            for suffix in ["_P12_BASE64", "_P12_PASSWORD"]:
                full = name + suffix
                self.assertIn(f"          {full}: ${{{{ secrets.{full} }}}}", workflow)
        for name in MODULE.PROFILES:
            self.assertIn(f"          {name}_BASE64: ${{{{ secrets.{name}_BASE64 }}}}", workflow)


if __name__ == "__main__":
    unittest.main()
