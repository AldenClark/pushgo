import os
from pathlib import Path
import subprocess
import time
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
CLEANER = REPO_ROOT / "scripts" / "close_macos_problem_reporter.sh"
SYSTEM_REPORTER_COMMAND = (
    "/System/Library/CoreServices/Problem Reporter.app/Contents/MacOS/Problem Reporter"
)


class CloseMacOSProblemReporterTests(unittest.TestCase):
    def test_default_rule_closes_only_exact_system_reporter_process(self) -> None:
        target = subprocess.Popen(
            [SYSTEM_REPORTER_COMMAND, "30"],
            executable="/bin/sleep",
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        unrelated = subprocess.Popen(
            ["pushgo-unrelated-fixture", "30"],
            executable="/bin/sleep",
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        try:
            time.sleep(0.1)
            result = subprocess.run(
                [str(CLEANER)],
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertIn("problem_reporter_closed=", result.stdout)
            target.wait(timeout=2)
            self.assertIsNone(unrelated.poll())
        finally:
            for process in (target, unrelated):
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=2)

    def test_no_match_is_a_successful_noop(self) -> None:
        result = subprocess.run(
            [
                str(CLEANER),
                "--pattern",
                f"^pushgo-missing-problem-reporter-{os.getpid()}($| )",
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertEqual("", result.stdout)

    def test_watch_mode_closes_reporter_created_during_a_test_batch(self) -> None:
        pattern = f"^pushgo-delayed-problem-reporter-{os.getpid()}($| )"
        watch_owner = subprocess.Popen(
            ["pushgo-problem-reporter-watch-owner", "30"],
            executable="/bin/sleep",
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        monitor = subprocess.Popen(
            [
                str(CLEANER),
                "--pattern",
                pattern,
                "--watch-pid",
                str(watch_owner.pid),
                "--poll-interval",
                "0.05",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        target = None
        try:
            time.sleep(0.1)
            target = subprocess.Popen(
                [f"pushgo-delayed-problem-reporter-{os.getpid()}", "30"],
                executable="/bin/sleep",
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            target.wait(timeout=2)
            self.assertIsNone(monitor.poll(), "The monitor must remain active for later crashes.")
        finally:
            watch_owner.terminate()
            watch_owner.wait(timeout=2)
            stdout, stderr = monitor.communicate(timeout=2)
            if target is not None and target.poll() is None:
                target.terminate()
                target.wait(timeout=2)

        self.assertEqual(0, monitor.returncode, stderr)
        self.assertIn("problem_reporter_closed=1", stdout)


if __name__ == "__main__":
    unittest.main()
