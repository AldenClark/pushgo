import importlib.util
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "apple_watch_provisioning_smoke.py"
SPEC = importlib.util.spec_from_file_location("apple_watch_provisioning_smoke", MODULE_PATH)
smoke = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(smoke)


class ParsePairsTests(unittest.TestCase):
    def test_reads_nested_phone_and_watch_udids(self):
        payload = '{"pairs":[{"phone":{"udid":"PHONE-1"},"watch":{"udid":"WATCH-1"}}]}'
        self.assertEqual(smoke.parse_pairs(payload), {("phone-1", "watch-1")})

    def test_rejects_unknown_pair_shape(self):
        with self.assertRaises(smoke.SmokeError):
            smoke.parse_pairs('{"pairs":[{"companion":"PHONE-1","wrist":"WATCH-1"}]}')


if __name__ == "__main__":
    unittest.main()
