import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[1] / "verify_apple_localizations.py"
SPEC = importlib.util.spec_from_file_location("verify_apple_localizations", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class AppleLocalizationContractTests(unittest.TestCase):
    def catalog(self, values=None):
        values = values or {"en": "%1$@ has %2$lld", "zh-Hans": "%2$lld 个 %1$@", "zh-Hant": "%2$lld 個 %1$@"}
        return {
            "sourceLanguage": "en",
            "strings": {
                "summary": {
                    "localizations": {
                        locale: {"stringUnit": {"state": "translated", "value": value}}
                        for locale, value in values.items()
                    }
                }
            },
            "version": "1.0",
        }

    def validate(self, payload):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Localizable.xcstrings"
            path.write_text(json.dumps(payload), encoding="utf-8")
            return MODULE.validate_catalog(path)

    def test_reordered_positional_placeholders_pass(self):
        self.assertEqual([], self.validate(self.catalog()))

    def test_missing_locale_is_reported(self):
        payload = self.catalog()
        del payload["strings"]["summary"]["localizations"]["zh-Hant"]
        self.assertTrue(any("missing zh-Hant" in error for error in self.validate(payload)))

    def test_placeholder_loss_is_reported(self):
        payload = self.catalog()
        payload["strings"]["summary"]["localizations"]["zh-Hans"]["stringUnit"]["value"] = "%1$@"
        self.assertTrue(any("placeholder mismatch" in error for error in self.validate(payload)))

    def test_discovers_catalogs_added_under_any_production_root(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            expected = []
            for relative in ("Resources/Base.xcstrings", "Apps/iOS/App.xcstrings", "Extensions/NSE/NSE.xcstrings"):
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(json.dumps(self.catalog()), encoding="utf-8")
                expected.append(path)
            ignored = root / "Tests/Test.xcstrings"
            ignored.parent.mkdir(parents=True)
            ignored.write_text(json.dumps(self.catalog()), encoding="utf-8")
            self.assertEqual(sorted(expected), MODULE.discover_production_catalogs(root))


if __name__ == "__main__":
    unittest.main()
