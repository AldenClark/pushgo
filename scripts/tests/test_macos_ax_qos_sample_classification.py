"""A sampled Thing query is evidence capture, never a clean product result."""

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
HELPER = REPO / "scripts/ci/run_macos_adhoc_ui_diagnostic.sh"
CLASSIFIER = next(
    block
    for block in re.findall(r"<<'PY'[^\n]*\n(.*?)^PY(?:\n|$)", HELPER.read_text(), re.M | re.S)
    if '"sample_capture_status"' in block
)


class MacOSAXQoSSampleClassificationTests(unittest.TestCase):
    def classify(self, *, passed=0, failures=None, attachment_names=(), host=False, host_status=None):
        failures = failures or []
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            summary = root / "summary.json"
            legacy = root / "legacy.json"
            log = root / "native.log"
            status = root / "runner-status.txt"
            output = root / "classification.json"
            summary.write_text(json.dumps({
                "passedTests": passed,
                "failedTests": int(bool(failures)),
                "skippedTests": 0,
                "expectedFailures": 0,
                "runtimeWarnings": [],
                "testFailures": failures,
            }))
            legacy.write_text(json.dumps({"actions": {"_values": [{"actionResult": {"issues": {}}}]}}))
            log.write_text("")
            status.write_text("PASSED\n")
            activities = root / "activities.json"
            activities.write_text(json.dumps({"activities": [{"attachments": [{"name": name} for name in attachment_names]}]}))
            host_summary = root / "host-sample-summary.json"
            if host_status is not None:
                host_summary.write_text(json.dumps({"status": host_status}))
            fake_bin = root / "bin"
            fake_bin.mkdir()
            fake_xcrun = fake_bin / "xcrun"
            fake_xcrun.write_text(
                "#!/usr/bin/env python3\n"
                "import os\n"
                "print(open(os.environ['FAKE_ACTIVITY_JSON']).read())\n"
            )
            fake_xcrun.chmod(0o755)
            result = subprocess.run(
                [sys.executable, "-", str(summary), str(legacy), str(log), str(status),
                 "0" if passed else "65", "1", str(output),
                 "0" if host else "1", "1" if host else "0",
                 str(host_summary), "sample.xcresult"],
                input=CLASSIFIER,
                text=True,
                capture_output=True,
                env={**os.environ, "PYTHONPATH": str(REPO),
                     "PATH": str(fake_bin) + os.pathsep + os.environ["PATH"],
                     "FAKE_ACTIVITY_JSON": str(activities)},
                check=False,
            )
            return result.returncode, json.loads(output.read_text())

    def test_pure_sample_precondition_is_blocked(self):
        code, receipt = self.classify(failures=[{
            "testName": "thing()",
            "failureText": "failed - QUALITY_PRECONDITION: AX_QOS_SAMPLE_BLOCKED theme PID missing",
        }])
        self.assertEqual(code, 1)
        self.assertEqual((receipt["product_status"], receipt["test_system_status"]),
                         ("NOT_RUN", "BLOCKED"))

    def test_business_failure_is_not_hidden_by_sample_precondition(self):
        code, receipt = self.classify(failures=[
            {"testName": "thing()", "failureText": "XCTAssertEqual failed: stale Thing"},
            {"testName": "thing()", "failureText": "QUALITY_PRECONDITION: AX_QOS_SAMPLE_BLOCKED permission"},
        ])
        self.assertEqual(code, 1)
        self.assertEqual(receipt["product_status"], "FAILED")
        self.assertEqual(receipt["test_system_status"], "FAILED_TEST_SYSTEM")

    def test_native_pass_without_three_stacks_is_not_capture_success(self):
        code, receipt = self.classify(passed=1, attachment_names=("thing-ax-qos-query-timing",))
        self.assertEqual(code, 1)
        self.assertEqual((receipt["product_status"], receipt["test_system_status"]),
                         ("NOT_RUN", "FAILED_TEST_SYSTEM"))
        self.assertEqual(receipt["reason"], "three_pid_sample_attachments_missing")

    def test_all_stacks_keep_sampled_product_not_run(self):
        code, receipt = self.classify(passed=1, attachment_names=(
            "thing-ax-qos-query-timing", "thing-ax-qos-runner-sample",
            "thing-ax-qos-app-sample", "thing-ax-qos-theme-widget-sample",
        ))
        self.assertEqual(code, 0)
        self.assertEqual((receipt["product_status"], receipt["test_system_status"]),
                         ("NOT_RUN", "PASSED"))
        self.assertEqual(receipt["sample_capture_status"], "PASSED")

    def test_host_capture_keeps_sampled_product_not_run(self):
        code, receipt = self.classify(passed=1, host=True, host_status="CAPTURED")
        self.assertEqual(code, 0)
        self.assertEqual((receipt["product_status"], receipt["test_system_status"]),
                         ("NOT_RUN", "PASSED"))
        self.assertEqual(receipt["sample_capture_status"], "PASSED")

    def test_host_capture_missing_or_blocked_cannot_pass(self):
        for status in (None, "BLOCKED"):
            with self.subTest(status=status):
                code, receipt = self.classify(passed=1, host=True, host_status=status)
                self.assertEqual(code, 1)
                self.assertEqual((receipt["product_status"], receipt["test_system_status"]),
                                 ("NOT_RUN", "BLOCKED"))

    def test_host_precondition_does_not_become_product_failure(self):
        code, receipt = self.classify(host=True, host_status="BLOCKED", failures=[{
            "testName": "thing()",
            "failureText": "QUALITY_PRECONDITION: AX_QOS_HOST_SAMPLE_BLOCKED host sample denied",
        }])
        self.assertEqual(code, 1)
        self.assertEqual((receipt["product_status"], receipt["test_system_status"]),
                         ("NOT_RUN", "BLOCKED"))


if __name__ == "__main__":
    unittest.main()
