import hashlib
import tempfile
import unittest
from pathlib import Path

from scripts.record_apple_signing_acceptance import build_receipt


class AppleSigningAcceptanceTests(unittest.TestCase):
    def test_store_receipt_hashes_only_the_required_signed_candidates(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ipa = root / "candidate.ipa"
            pkg = root / "candidate.pkg"
            ipa.write_bytes(b"signed ipa bytes")
            pkg.write_bytes(b"signed pkg bytes")

            receipt = build_receipt(
                "app-store",
                "1.3.3",
                [ipa, pkg],
                {"profile-entitlements", "fastlane-archive-export"},
            )

        self.assertEqual("PASSED", receipt["status"])
        self.assertEqual("NOT_PERFORMED", receipt["publication"])
        self.assertEqual("NOT_CERTIFIED", receipt["product_acceptance"])
        self.assertEqual(
            {hashlib.sha256(b"signed ipa bytes").hexdigest(), hashlib.sha256(b"signed pkg bytes").hexdigest()},
            {artifact["sha256"] for artifact in receipt["artifacts"]},
        )

    def test_receipt_rejects_missing_validation_or_signing_material(self):
        with tempfile.TemporaryDirectory() as directory:
            p12 = Path(directory) / "identity.p12"
            p12.write_bytes(b"private signing material")
            with self.assertRaisesRegex(ValueError, "exactly"):
                build_receipt("dmg", "1.3.3", [p12], {"developer-id-signing"})
            with self.assertRaisesRegex(ValueError, "signing material"):
                build_receipt(
                    "dmg",
                    "1.3.3",
                    [p12],
                    {"direct-profile-entitlements", "developer-id-signing", "notarization-stapling"},
                )


if __name__ == "__main__":
    unittest.main()
