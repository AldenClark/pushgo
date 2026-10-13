import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest import mock


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

    def test_relaunch_cannot_accept_the_previous_process_state(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state_dir = root / "Documents" / "watch-provisioning-smoke"
            state_dir.mkdir(parents=True)
            state = state_dir / "state.json"
            response = state_dir / "response.json"
            state.write_text('{"watch_alert_window_minutes":15}')
            response.write_text('{"ok":true}')
            store = root / "persisted-store.sqlite"
            store.write_bytes(b"preserve-existing-store")
            def observe_launch(*args, **kwargs):
                if args[0] == "terminate":
                    # Model the old process's final asynchronous state write.
                    state.write_text('{"watch_alert_window_minutes":15}')
                    return ""
                self.assertFalse(state.exists())
                self.assertFalse(response.exists())
                self.assertEqual(store.read_bytes(), b"preserve-existing-store")
                return ""
            with mock.patch.object(smoke, "simctl", side_effect=observe_launch) as launch:
                self.assertEqual(smoke.launch("watch", "app", root, None), state)
                self.assertEqual([call.args[0] for call in launch.call_args_list], ["terminate", "launch"])

    def test_relaunch_does_not_continue_when_termination_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.object(smoke, "simctl", side_effect=smoke.SmokeError("device unavailable")) as launch:
                with self.assertRaisesRegex(smoke.SmokeError, "device unavailable"):
                    smoke.launch("watch", "app", Path(directory), None)
                launch.assert_called_once_with("terminate", "watch", "app")

    def test_relaunch_accepts_an_already_stopped_app(self):
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.object(smoke, "simctl", side_effect=[smoke.SmokeError("found nothing to terminate"), ""]) as launch:
                smoke.launch("watch", "app", Path(directory), None)
                self.assertEqual([call.args[0] for call in launch.call_args_list], ["terminate", "launch"])


if __name__ == "__main__":
    unittest.main()
