import importlib.util
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "verify_update_distribution", REPO / "scripts/verify_update_distribution.py"
)
assert SPEC and SPEC.loader
VERIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY)


class UpdateDistributionContractTests(unittest.TestCase):
    def test_repository_metadata_satisfies_distribution_contract(self):
        VERIFY.validate_appcast(REPO / "release/appcast.xml")
        VERIFY.validate_app_store(REPO / "release/appstore.json")
        VERIFY.validate_update_notes(REPO / "release/update-notes")

    def test_non_https_enclosure_is_rejected(self):
        source = (REPO / "release/appcast.xml").read_text(encoding="utf-8")
        broken = source.replace('url="https://', 'url="http://', 1)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "appcast.xml"
            path.write_text(broken, encoding="utf-8")
            with self.assertRaisesRegex(VERIFY.ContractError, "HTTPS URL"):
                VERIFY.validate_appcast(path)


if __name__ == "__main__":
    unittest.main()
