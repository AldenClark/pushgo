from __future__ import annotations

import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

from scripts import verify_apple_test_execution
from scripts.verify_apple_test_execution import (
    executed_test_count,
    runtime_warning_messages,
    test_count_matches_selection,
)


class VerifyAppleTestExecutionTests(unittest.TestCase):
    def test_reads_passing_total(self) -> None:
        self.assertEqual(executed_test_count({"passedTests": 2, "failedTests": 0}), 2)

    def test_rejects_failed_native_test_even_when_other_tests_passed(self) -> None:
        with self.assertRaisesRegex(ValueError, "contains failed tests"):
            executed_test_count({"passedTests": 2, "failedTests": 1})

    def test_counts_strict_expected_failure_as_executed(self) -> None:
        self.assertEqual(
            executed_test_count(
                {"passedTests": 0, "failedTests": 0, "expectedFailures": 1},
                allow_expected_failures=True,
            ),
            1,
        )

    def test_rejects_expected_failure_in_an_ordinary_product_lane(self) -> None:
        with self.assertRaises(ValueError):
            executed_test_count(
                {"passedTests": 0, "failedTests": 0, "expectedFailures": 1}
            )

    def test_all_skipped_is_zero_for_rejection_by_runner(self) -> None:
        self.assertEqual(
            executed_test_count({"passedTests": 0, "failedTests": 0, "skippedTests": 3}),
            0,
        )

    def test_rejects_non_integer_total(self) -> None:
        with self.assertRaises(ValueError):
            executed_test_count({"passedTests": "3", "failedTests": 0})

    def test_exact_selection_requires_every_selected_method_to_execute(self) -> None:
        self.assertTrue(test_count_matches_selection(2, 2))
        self.assertFalse(test_count_matches_selection(1, 2))
        self.assertTrue(test_count_matches_selection(7, None))

    def test_runtime_warnings_are_read_from_native_result_not_log_heuristics(self) -> None:
        self.assertEqual(
            ["test runner main-thread warning"],
            runtime_warning_messages({"runtimeWarnings": [{"message": "test runner main-thread warning"}]}),
        )
        with self.assertRaises(ValueError):
            runtime_warning_messages({"runtimeWarnings": [{"message": 1}]})

    def test_summary_reader_retries_only_receipt_read_until_xcresult_stabilizes(self) -> None:
        transient = subprocess.CalledProcessError(
            1,
            ["xcrun", "xcresulttool"],
            stderr="result bundle is still importing an attachment",
        )
        completed = subprocess.CompletedProcess(
            args=["xcrun", "xcresulttool"],
            returncode=0,
            stdout=json.dumps({"passedTests": 1, "failedTests": 0, "runtimeWarnings": []}),
        )
        with patch.object(
            verify_apple_test_execution.subprocess,
            "run",
            side_effect=[transient, completed],
        ) as run, patch.object(verify_apple_test_execution.time, "sleep") as sleep:
            summary = verify_apple_test_execution.read_native_summary(Path("result.xcresult"))

        self.assertEqual(1, summary["passedTests"])
        self.assertEqual(2, run.call_count)
        sleep.assert_called_once_with(verify_apple_test_execution.RESULT_READ_RETRY_SECONDS)

    def test_summary_reader_rejects_bundle_that_never_stabilizes(self) -> None:
        transient = subprocess.CalledProcessError(
            1,
            ["xcrun", "xcresulttool"],
            stderr="result bundle is unreadable",
        )
        with patch.object(
            verify_apple_test_execution.subprocess,
            "run",
            side_effect=transient,
        ) as run, patch.object(verify_apple_test_execution.time, "sleep") as sleep:
            with self.assertRaises(subprocess.CalledProcessError):
                verify_apple_test_execution.read_native_summary(Path("result.xcresult"))

        self.assertEqual(verify_apple_test_execution.RESULT_READ_ATTEMPTS, run.call_count)
        self.assertEqual(verify_apple_test_execution.RESULT_READ_ATTEMPTS - 1, sleep.call_count)


if __name__ == "__main__":
    unittest.main()
