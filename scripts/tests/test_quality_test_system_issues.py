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
        registry["issues"][0]["status"] = "active"
        registry["issues"][0].pop("resolved_on", None)
        registry["issues"][0]["expires_on"] = "2026-08-27"

        with self.assertRaisesRegex(ValueError, "expired"):
            ISSUES.validate_registry(registry, date(2026, 8, 28))

    def test_active_flake_cannot_be_renewed_beyond_fourteen_days(self):
        registry = copy.deepcopy(self.registry)
        registry["issues"][0]["status"] = "active"
        registry["issues"][0].pop("resolved_on", None)
        registry["issues"][0]["expires_on"] = "2026-09-12"

        with self.assertRaisesRegex(ValueError, "exceeds 14 days"):
            ISSUES.validate_registry(registry, date(2026, 8, 28))

    def test_unbacked_quarantine_is_rejected(self):
        registry = copy.deepcopy(self.registry)
        registry["issues"][0]["quarantined"] = True

        with self.assertRaisesRegex(ValueError, "replacement_evidence"):
            ISSUES.validate_registry(registry, date(2026, 8, 28))

    def test_resolved_runner_signature_no_longer_matches(self):
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

        self.assertEqual([], matched)
        self.assertEqual([], unrelated)

    def test_only_active_quality_precondition_has_owned_attribution(self):
        watch = ISSUES.active_matches(
            self.registry,
            "Failed to initialize for UI testing because the runner was unavailable",
        )
        precondition = ISSUES.active_matches(
            self.registry,
            "QUALITY_PRECONDITION: app-owned fixture was not ready",
        )

        self.assertEqual([], watch)
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

    def test_quality_precondition_inside_test_is_zero_retry_blocking_attribution(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "precondition.log"
            log.write_text(
                "Test Case '-[PushGoUITests testPurpose]' started.\n"
                "QUALITY_PRECONDITION: app-owned fixture was not ready\n",
                encoding="utf-8",
            )
            classified = subprocess.run(
                [
                    "python3",
                    str(REPO / "scripts/quality_test_system_issues.py"),
                    "--match-file",
                    str(log),
                ],
                cwd=REPO,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )
            retryable = subprocess.run(
                [
                    "python3",
                    str(REPO / "scripts/quality_test_system_issues.py"),
                    "--match-file",
                    str(log),
                    "--retryable-only",
                ],
                cwd=REPO,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )

        self.assertEqual(0, classified.returncode)
        self.assertIn("apple-quality-precondition", classified.stdout)
        self.assertNotEqual(0, retryable.returncode)

    def test_ios_runner_rejects_any_retry_before_using_simulator(self):
        process = subprocess.run(
            [str(REPO / "scripts/run_ios_ui_tests.sh")],
            cwd=REPO,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "MAX_RETRIES": "1"},
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )

        self.assertEqual(2, process.returncode)
        self.assertIn("ios_ui_retries_are_disabled:1", process.stdout)
        runner = (REPO / "scripts/run_ios_ui_tests.sh").read_text()
        self.assertLess(
            runner.index("reason=ios_ui_retries_are_disabled"),
            runner.index("reason=pushgo_apple_ui_lease_busy"),
            "Pure argument validation must not contend for the shared Apple UI lease.",
        )

    def test_ios_runner_rejects_system_notification_scope_before_using_simulator(self):
        process = subprocess.run(
            [str(REPO / "scripts/run_ios_ui_tests.sh")],
            cwd=REPO,
            env={
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "TEST_SCOPES": (
                    "PushGo-iOSUITests/PushGo_iOSSystemNotificationTests/"
                    "testSystemNotificationTapColdLaunchesAccurateReadDetailAndPersists"
                ),
            },
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )

        self.assertEqual(2, process.returncode)
        self.assertIn(
            "ios_system_notification_scope_requires_dedicated_runner",
            process.stdout,
        )
        self.assertNotIn("simulator_id=", process.stdout)
        runner = (REPO / "scripts/run_ios_ui_tests.sh").read_text()
        self.assertLess(
            runner.index("reason=ios_system_notification_scope_requires_dedicated_runner"),
            runner.index("reason=pushgo_apple_ui_lease_busy"),
        )

    def test_startup_reliability_rejects_invalid_iterations_before_doctor(self):
        process = subprocess.run(
            [str(REPO / "scripts/run_ios_startup_reliability.sh")],
            cwd=REPO,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "ITERATIONS": "0"},
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )

        self.assertEqual(2, process.returncode)
        self.assertIn("iterations_must_be_between_1_and_100:0", process.stdout)
        self.assertNotIn("simulator_id=", process.stdout)

    def test_macos_startup_reliability_rejects_invalid_iterations_before_ui_preflight(self):
        process = subprocess.run(
            [str(REPO / "scripts/run_macos_startup_reliability.sh")],
            cwd=REPO,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "ITERATIONS": "101"},
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )

        self.assertEqual(2, process.returncode)
        self.assertIn("iterations_must_be_between_1_and_100:101", process.stdout)
        self.assertNotIn("macos_console_must_be_unlocked", process.stdout)

    def test_macos_startup_campaign_keeps_business_oracle_and_crash_cleanup_in_every_repetition(self):
        runner = (REPO / "scripts/run_macos_startup_reliability.sh").read_text()
        test_source = (REPO / "Tests/PushGo-macOSUITests/PushGo_macOSUITests.swift").read_text()
        journey = test_source.split(
            "func testQualitySessionUsesAppOwnedStoreAndReachesFunctionalEmptyState()",
            1,
        )[1].split("\n    @MainActor", 1)[0]

        self.assertIn("for (( iteration = 1; iteration <= iterations; iteration++ )); do", runner)
        self.assertNotIn('-test-iterations "$iterations"', runner)
        self.assertNotIn("-test-repetition-relaunch-enabled YES", runner)
        self.assertIn('"business_retries": 0', runner)
        self.assertIn('"$problem_reporter_cleaner" --watch-pid "$$"', runner)
        self.assertIn('openSidebarTab("settings"', journey)
        self.assertIn('openSidebarTab("messages"', journey)
        self.assertGreaterEqual(journey.count('identifier: "state.messages.empty"'), 2)

        launch_helper = test_source.split("private func launch(_ context: LaunchContext)", 1)[1].split(
            "\n    @MainActor",
            1,
        )[0]
        self.assertIn("context.app.launch()", launch_helper)
        self.assertIn("context.app.activate()", launch_helper)
        self.assertIn("activation_failures == failed", runner)
        self.assertIn('"calibration_only": total != 50', runner)
        self.assertIn('"startup_reliability_exit_criteria_met": total == 50', runner)

        ios_runner = (REPO / "scripts/run_ios_startup_reliability.sh").read_text()
        self.assertIn('"calibration_only": total != 50', ios_runner)
        self.assertIn('"startup_reliability_exit_criteria_met": total == 50', ios_runner)



if __name__ == "__main__":
    unittest.main()
