import unittest
import plistlib
from pathlib import Path
import tempfile
from types import SimpleNamespace
from unittest.mock import patch
from scripts.verify_signed_keychain_groups import verify, verify_metadata


class SignedKeychainGroupsTests(unittest.TestCase):
    def test_embedded_watch_app_cannot_escape_the_signed_bundle_gate(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "PushGo.app"
            watch = app / "Watch/PushGoWatch.app"
            watch.mkdir(parents=True)
            (app / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "io.ethan.pushgo",
                "PushGoKeychainAccessGroup": "FIXTURE.io.ethan.pushgo.shared",
            }))
            (watch / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "io.ethan.pushgo.watchkitapp"}))
            signature = SimpleNamespace(stdout=plistlib.dumps({"keychain-access-groups": ["FIXTURE.io.ethan.pushgo.shared"]}))
            with patch("scripts.verify_signed_keychain_groups.subprocess.run", return_value=signature), self.assertRaisesRegex(ValueError, "missing"):
                verify(app)

    def test_app_and_notification_extension_cannot_omit_runtime_group(self):
        for identity in ["io.ethan.pushgo", "io.ethan.pushgo.NotificationServiceExtension",
                         "io.ethan.pushgo.watchkitapp", "io.ethan.pushgo.watchkitapp.NotificationServiceExtension"]:
            with self.subTest(identity=identity), self.assertRaisesRegex(ValueError, "missing"):
                verify_metadata({"CFBundleIdentifier": identity}, {})

    def test_unsigned_build_lost_prefix_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "not signed"):
            verify_metadata(
                {"PushGoKeychainAccessGroup": "io.ethan.pushgo.shared"},
                {"keychain-access-groups": ["FIXTURE.io.ethan.pushgo.shared"]},
            )

    def test_correctly_resolved_group_matches_actual_signature(self):
        self.assertTrue(verify_metadata(
            {"PushGoKeychainAccessGroup": "FIXTURE.io.ethan.pushgo.shared"},
            {"keychain-access-groups": ["FIXTURE.io.ethan.pushgo.shared"]},
        ))

    def test_unresolved_or_wrong_team_cannot_pass(self):
        for group in ["$(AppIdentifierPrefix)io.ethan.pushgo.shared", "OTHER.io.ethan.pushgo.shared"]:
            with self.subTest(group=group), self.assertRaises(ValueError):
                verify_metadata({"PushGoKeychainAccessGroup": group},
                                {"keychain-access-groups": ["FIXTURE.io.ethan.pushgo.shared"]})
