import os
from pathlib import Path
import subprocess
import json
import sys
import tempfile
import time
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
CLEANER = REPO_ROOT / "scripts" / "close_macos_problem_reporter.sh"
SYSTEM_REPORTER_COMMAND = (
    "/System/Library/CoreServices/Problem Reporter.app/Contents/MacOS/Problem Reporter"
)
CURRENT_REPORTER_COMMAND = (
    "/System/Library/CoreServices/UserNotificationCenter.app/Contents/MacOS/"
    "UserNotificationCenter"
)


class CloseMacOSProblemReporterTests(unittest.TestCase):
    def test_default_rule_closes_both_exact_system_reporter_processes_only(self) -> None:
        legacy_target = subprocess.Popen(
            [f"pushgo-test-legacy-reporter-{os.getpid()}", "30"],
            executable="/bin/sleep",
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        current_target = subprocess.Popen(
            [f"pushgo-test-current-reporter-{os.getpid()}", "30"],
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
            # Default-pattern coverage must not create globally named system
            # processes: a concurrent UI watcher can kill those fixtures before
            # this test's cleaner, making a correct cleanup look like failure.
            # Keep the native signals/liveness checks; scope discovery to only
            # our owned PIDs and evaluate the cleaner's actual default pattern.
            with tempfile.TemporaryDirectory() as directory:
                fixture = Path(directory) / "processes.json"
                fixture.write_text(json.dumps([
                    [legacy_target.pid, SYSTEM_REPORTER_COMMAND + " 30"],
                    [current_target.pid, CURRENT_REPORTER_COMMAND + " 30"],
                    [unrelated.pid, "pushgo-unrelated-fixture 30"],
                ]))
                pgrep = Path(directory) / "pgrep"
                pgrep.write_text("#!" + sys.executable + "\n" +
                    "import json, os, re, sys\n" +
                    "assert sys.argv[1] == '-f'\n" +
                    "matches = [str(pid) for pid, command in json.load(open(os.environ['PUSHGO_TEST_PROCESSES'])) if re.search(sys.argv[2], command)]\n" +
                    "print('\\n'.join(matches)) if matches else None\n" +
                    "sys.exit(0 if matches else 1)\n")
                pgrep.chmod(0o755)
                result = subprocess.run(
                    [str(CLEANER)], check=True, capture_output=True, text=True,
                    env={**os.environ, "PATH": directory + os.pathsep + os.environ["PATH"],
                         "PUSHGO_TEST_PROCESSES": str(fixture)},
                )
            self.assertIn("problem_reporter_closed=2", result.stdout)
            legacy_target.wait(timeout=2)
            current_target.wait(timeout=2)
            self.assertIsNone(unrelated.poll())
        finally:
            for process in (legacy_target, current_target, unrelated):
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
