import copy
import importlib.util
import json
import subprocess
import tempfile
import unittest
from datetime import date
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "quality_test_system_issues", REPO / "scripts/quality_test_system_issues.py"
)
assert SPEC and SPEC.loader
ISSUES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ISSUES)


class QualityTestSystemIssueTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.registry = json.loads(
            (REPO / "config/quality-test-system-issues.json").read_text(encoding="utf-8")
        )

    def test_current_registry_has_owned_unexpired_issues(self):
        ISSUES.validate_registry(self.registry, date.today())

        self.assertTrue(self.registry["issues"])
        self.assertTrue(all(issue["owner"] for issue in self.registry["issues"]))

    def test_expired_active_flake_is_rejected(self):
        registry = copy.deepcopy(self.registry)
        registry["issues"][0]["expires_on"] = "2026-08-27"

        with self.assertRaisesRegex(ValueError, "expired"):
            ISSUES.validate_registry(registry, date(2026, 8, 28))

    def test_active_flake_cannot_be_renewed_beyond_fourteen_days(self):
        registry = copy.deepcopy(self.registry)
        registry["issues"][0]["expires_on"] = "2026-09-12"

        with self.assertRaisesRegex(ValueError, "exceeds 14 days"):
            ISSUES.validate_registry(registry, date(2026, 8, 28))

    def test_unbacked_quarantine_is_rejected(self):
        registry = copy.deepcopy(self.registry)
        registry["issues"][0]["quarantined"] = True

        with self.assertRaisesRegex(ValueError, "replacement_evidence"):
            ISSUES.validate_registry(registry, date(2026, 8, 28))

    def test_only_exact_registered_signature_matches(self):
        matched = ISSUES.active_matches(
            self.registry,
            "Failed to launch app with identifier: io.example.xctrunner",
            retryable_only=True,
        )
        unrelated = ISSUES.active_matches(
            self.registry,
            "Expected accurate channel row to exist",
            retryable_only=True,
        )

        self.assertEqual(["apple-simulator-xctest-runner-launch"], [issue["id"] for issue in matched])
        self.assertEqual([], unrelated)

    def test_watch_runner_and_quality_precondition_have_owned_attribution(self):
        watch = ISSUES.active_matches(
            self.registry,
            "Failed to initialize for UI testing because the runner was unavailable",
        )
        precondition = ISSUES.active_matches(
            self.registry,
            "QUALITY_PRECONDITION: app-owned fixture was not ready",
        )

        self.assertEqual(
            ["apple-simulator-xctest-runner-launch"],
            [issue["id"] for issue in watch],
        )
        self.assertEqual(
            ["apple-quality-precondition"],
            [issue["id"] for issue in precondition],
        )

    def test_runner_signature_after_product_test_started_is_not_classified(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "mixed.log"
            log.write_text(
                "Test Case '-[PushGoUITests testPurpose]' started.\n"
                "Failed to launch app with identifier: io.example.xctrunner\n",
                encoding="utf-8",
            )
            process = subprocess.run(
                [
                    "python3",
                    str(REPO / "scripts/quality_test_system_issues.py"),
                    "--match-file",
                    str(log),
                    "--reject-if-matches",
                    r"Test Case '-\[",
                    "--retryable-only",
                ],
                cwd=REPO,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )

        self.assertNotEqual(0, process.returncode)
        self.assertNotIn("Traceback", process.stdout)

    def test_ios_runner_rejects_more_than_one_retry_before_using_simulator(self):
        process = subprocess.run(
            [str(REPO / "scripts/run_ios_ui_tests.sh")],
            cwd=REPO,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "MAX_RETRIES": "2"},
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )

        self.assertEqual(2, process.returncode)
        self.assertIn("ios_ui_max_retries_must_be_zero_or_one:2", process.stdout)


if __name__ == "__main__":
    unittest.main()
