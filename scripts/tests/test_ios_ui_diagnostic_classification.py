"""Keep a failed iOS UI method visible when a sibling fails its precondition."""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]
HELPER = REPO / "scripts/ci/run_ios_ui_diagnostic.sh"
CLASSIFIER = next(
    block
    for block in re.findall(r"<<'PY'[^\n]*\n(.*?)^PY(?:\n|$)", HELPER.read_text(), re.M | re.S)
    if '"native_failures"' in block
)


class IOSUIDiagnosticClassificationTests(unittest.TestCase):
    def classify(self, failures: list[dict[str, str]], *, passed: int = 0,
                 failed_count: int | None = None):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            summary = root / "summary.json"
            legacy = root / "legacy.json"
            output = root / "classification.json"
            summary.write_text(json.dumps({
                "passedTests": passed,
                "failedTests": len(failures) if failed_count is None else failed_count,
                "skippedTests": 0,
                "expectedFailures": 0,
                "testFailures": failures,
                "runtimeWarnings": [],
            }))
            legacy.write_text(json.dumps({
                "actions": {"_values": [{"actionResult": {"issues": {}}}]}
            }))
            result = subprocess.run(
                [sys.executable, "-", str(summary), str(legacy),
                 "0" if not failures else "65", "0" if not failures else "1",
                 str(passed + (len(failures) if failed_count is None else failed_count)), str(output)],
                input=CLASSIFIER,
                text=True,
                capture_output=True,
                env={**os.environ, "PYTHONPATH": str(REPO)},
                check=False,
            )
            return result.returncode, json.loads(output.read_text())

    def test_real_product_failure_survives_sibling_precondition(self):
        code, receipt = self.classify([
            {"testName": "history()", "failureText": "XCTAssertEqual failed: wrong body != canonical body"},
            {"testName": "facet()", "failureText": "failed - QUALITY_PRECONDITION: seeding.messages"},
        ])
        self.assertEqual(code, 1)
        self.assertEqual((receipt["product_status"], receipt["test_system_status"]),
                         ("FAILED", "FAILED_TEST_SYSTEM"))
        self.assertEqual([item["test_name"] for item in receipt["native_failures"]],
                         ["history()", "facet()"])

    def test_exact_ax_failure_is_not_invented_as_product_failure(self):
        code, receipt = self.classify([
            {"testName": "history()", "failureText":
             'Failed to determine hittability of "action.messages.filter" Other: '
             "Activation point invalid and no suggested hit points based on element frame"},
            {"testName": "facet()", "failureText": "failed - QUALITY_PRECONDITION: seeding.messages"},
        ])
        self.assertEqual(code, 1)
        self.assertEqual((receipt["product_status"], receipt["test_system_status"]),
                         ("NOT_RUN", "FAILED_TEST_SYSTEM"))
        self.assertEqual(receipt["reason"], "native_ax_actionability_unresolved")

    def test_pure_precondition_remains_blocked(self):
        code, receipt = self.classify([
            {"testName": "facet()", "failureText": "failed - QUALITY_PRECONDITION: seeding.messages"},
        ])
        self.assertEqual(code, 1)
        self.assertEqual((receipt["product_status"], receipt["test_system_status"]),
                         ("NOT_RUN", "BLOCKED"))

    def test_clean_method_still_passes(self):
        code, receipt = self.classify([], passed=1)
        self.assertEqual(code, 0)
        self.assertEqual((receipt["product_status"], receipt["test_system_status"]),
                         ("PASSED", "PASSED"))

    def test_missing_native_failure_details_fails_closed(self):
        code, receipt = self.classify([], failed_count=1)
        self.assertEqual(code, 1)
        self.assertEqual((receipt["product_status"], receipt["test_system_status"]),
                         ("NOT_RUN", "FAILED_TEST_SYSTEM"))
        self.assertEqual(receipt["reason"], "native_result_unreadable:ValueError")


if __name__ == "__main__":
    unittest.main()
