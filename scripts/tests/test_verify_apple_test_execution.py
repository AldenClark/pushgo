from __future__ import annotations

import unittest

from scripts.verify_apple_test_execution import executed_test_count


class VerifyAppleTestExecutionTests(unittest.TestCase):
    def test_reads_positive_total(self) -> None:
        self.assertEqual(executed_test_count({"passedTests": 2, "failedTests": 1}), 3)

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


if __name__ == "__main__":
    unittest.main()
