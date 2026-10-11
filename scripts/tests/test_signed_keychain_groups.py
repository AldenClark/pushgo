import unittest
from scripts.verify_signed_keychain_groups import verify_metadata


class SignedKeychainGroupsTests(unittest.TestCase):
    def test_app_and_notification_extension_cannot_omit_runtime_group(self):
        for identity in ["io.ethan.pushgo", "io.ethan.pushgo.NotificationServiceExtension"]:
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
