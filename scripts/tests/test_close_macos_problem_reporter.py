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


if __name__ == "__main__":
    unittest.main()
