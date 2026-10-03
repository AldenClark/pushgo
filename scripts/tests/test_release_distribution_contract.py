import importlib.util
import plistlib
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "verify_release_distribution_contract",
    REPO / "scripts/verify_release_distribution_contract.py",
)
assert SPEC and SPEC.loader
VERIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY)


class ReleaseDistributionContractTests(unittest.TestCase):
    def test_both_macos_products_register_the_real_system_route(self):
        for relative_path in (
            "config/PushGo-macOS-Info.plist",
            "Apps/PushGo-macOS/PushGo-macOS-DMG-Info.plist",
        ):
            with self.subTest(relative_path=relative_path):
                self.assertIn("pushgo", VERIFY.registered_url_schemes(REPO / relative_path))

    def test_unrelated_registration_does_not_satisfy_the_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Info.plist"
            with path.open("wb") as stream:
                plistlib.dump(
                    {"CFBundleURLTypes": [{"CFBundleURLSchemes": ["unrelated-scheme"]}]},
                    stream,
                )

            self.assertNotIn("pushgo", VERIFY.registered_url_schemes(path))


if __name__ == "__main__":
    unittest.main()
