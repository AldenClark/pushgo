import copy
from datetime import date
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from scripts import release_smoke, quality_test_system_issues


class ReleaseSmokeTests(unittest.TestCase):
    def test_gateway_pair_cannot_float_to_an_unidentified_server(self):
        manifest = json.loads((release_smoke.ROOT / "config/release-smoke.json").read_text())
        profile = manifest["profiles"]["gateway-integration"]
        release_smoke.validate_profile(profile)
        for repository, revision in (("AldenClark/pushgo-gateway", "main"), ("", profile["gateway_revision"]), ("AldenClark/pushgo-gateway", "")):
            invalid = dict(profile, gateway_repository=repository, gateway_revision=revision)
            with self.assertRaisesRegex(ValueError, "immutable"):
                release_smoke.validate_profile(invalid)

    def test_ui_count_alone_cannot_accept_wrong_test_or_failed_result(self):
        tree = {"testNodes": [{"children": [{"nodeType": "Test Case", "nodeIdentifier": "Suite/testCore()", "result": "Passed"}]}]}
        release_smoke.verify_ui_identities(tree, ["Target/Suite/testCore"])
        for identifier, result in (("Suite/testOther()", "Passed"), ("Suite/testCore()", "Failed")):
            tree["testNodes"][0]["children"][0].update(nodeIdentifier=identifier, result=result)
            with self.assertRaises(ValueError):
                release_smoke.verify_ui_identities(tree, ["Target/Suite/testCore"])

    def test_old_release_waiver_cannot_follow_new_product_or_tag(self):
        with patch.dict(os.environ, {"GITHUB_REF_TYPE": "branch"}):
            release_smoke.validate_release_version("1.3.3", {"1.3.3"})
            with self.assertRaises(ValueError):
                release_smoke.validate_release_version("1.3.3", {"1.3.4"})
        with patch.dict(os.environ, {"GITHUB_REF_TYPE": "tag", "GITHUB_REF_NAME": "v1.3.4"}):
            with self.assertRaises(ValueError):
                release_smoke.validate_release_version("1.3.3", {"1.3.3"})

    def events(self):
        suite = {"id": "Module.Suite", "kind": "suite", "name": "Suite"}
        test = {"id": "Module.Suite/test()", "kind": "function", "name": "test()"}
        return [{"version": 0, "kind": "test", "payload": t} for t in (suite, test)] + [
            {"version": 0, "kind": "event", "payload": {"kind": k, "testID": t["id"]}}
            for k in ("testStarted", "testEnded") for t in (suite, test)
        ] + [{"version": 0, "kind": "event", "payload": {"kind": "runEnded"}}]

    def verify(self, rows):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "events.jsonl"
            path.write_text("\n".join(json.dumps(r) for r in rows))
            return release_smoke.verify_core_events(path, ["Suite"])

    def test_native_events_require_full_execution(self):
        self.assertEqual(self.verify(self.events()), 1)
        for rows in ([], self.events()[:-1], [r for r in self.events() if r["payload"].get("kind") != "testEnded"]):
            with self.assertRaises(ValueError):
                self.verify(rows)

    def test_skips_and_assertion_issues_cannot_green(self):
        for kind in ("testSkipped", "issueRecorded"):
            rows = self.events() + [{"version": 0, "kind": "event", "payload": {"kind": kind}}]
            with self.assertRaises(ValueError):
                self.verify(rows)

    def test_mismatched_suite_cannot_green(self):
        rows = self.events()
        rows[0]["payload"]["name"] = "OtherSuite"
        with self.assertRaises(ValueError):
            self.verify(rows)

    def test_each_ui_selector_exists_in_owned_source(self):
        manifest = json.loads((release_smoke.ROOT / "config/release-smoke.json").read_text())
        for profile in manifest["profiles"].values():
            release_smoke.validate_profile(profile)
        wrong = copy.deepcopy(manifest["profiles"]["ios"])
        wrong["tests"][0] += "Typo"
        with self.assertRaisesRegex(ValueError, "missing"):
            release_smoke.validate_profile(wrong)
        wrong["tests"] = [wrong["tests"][0]] * 2
        with self.assertRaisesRegex(ValueError, "duplicate"):
            release_smoke.validate_profile(wrong)

    def test_authorized_expiry_waiver_is_version_and_issue_specific(self):
        registry = json.loads((release_smoke.ROOT / "config/quality-test-system-issues.json").read_text())
        today = date(2026, 10, 5)
        with patch.dict(os.environ, {"PUSHGO_RELEASE_SMOKE_VERSION": "1.3.3"}):
            quality_test_system_issues.validate_registry(registry, today)
            self.assertEqual(quality_test_system_issues.active_matches(registry,
                "Thread running at User-interactive quality-of-service class waiting on a lower QoS thread running at Default quality-of-service class. Investigate ways to avoid priority inversions")[0]["id"], "apple-xctest-qos-priority-inversion")
            other = copy.deepcopy(registry)
            other["issues"][-1]["id"] = "other-expired-issue"
            with self.assertRaisesRegex(ValueError, "expired"):
                quality_test_system_issues.validate_registry(other, today)
        with patch.dict(os.environ, {"PUSHGO_RELEASE_SMOKE_VERSION": "1.3.4"}):
            with self.assertRaisesRegex(ValueError, "expired"):
                quality_test_system_issues.validate_registry(registry, today)

    def test_manifest_waivers_are_bound_to_product_version_and_tag(self):
        manifest = json.loads((release_smoke.ROOT / "config/release-smoke.json").read_text())
        expected = {waiver["id"] for waiver in manifest["governance_waivers"]}
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(expected, release_smoke.active_governance_waivers())
        with patch.dict(os.environ, {"PUSHGO_RELEASE_SMOKE_VERSION": "1.3.4"}):
            self.assertEqual(set(), release_smoke.active_governance_waivers())
            future = copy.deepcopy(manifest)
            future["release_version"] = "1.3.4"
            self.assertEqual(
                set(),
                release_smoke.active_governance_waivers(future, versions={"1.3.4"}),
                "1.3.3 waivers do not follow a future product and manifest version",
            )
        with patch.dict(os.environ, {"GITHUB_REF_TYPE": "tag", "GITHUB_REF_NAME": "v1.3.4"}):
            with self.assertRaisesRegex(ValueError, "selected tag"):
                release_smoke.active_governance_waivers()
