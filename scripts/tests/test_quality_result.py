import json
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]


class QualityResultTests(unittest.TestCase):
    def run_result(self, *extra):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "result.json"
            process = subprocess.run(
                [
                    "python3",
                    str(REPO / "scripts/quality_result.py"),
                    "--output",
                    str(output),
                    "--platform",
                    "apple",
                    "--lane",
                    "unit-test",
                    "--product-status",
                    "NOT_RUN",
                    *extra,
                ],
                cwd=REPO,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )
            payload = json.loads(output.read_text(encoding="utf-8")) if output.exists() else None
            return process, payload

    def test_blocked_receipt_records_deduplicated_active_precondition_ids(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "result.json"
            subprocess.run(
                [
                    "python3",
                    str(REPO / "scripts/quality_result.py"),
                    "--output",
                    str(output),
                    "--platform",
                    "apple",
                    "--lane",
                    "unit-test",
                    "--product-status",
                    "NOT_RUN",
                    "--test-system-status",
                    "BLOCKED",
                    "--test-system-issue-id",
                    "apple-quality-precondition",
                    "--test-system-issue-id",
                    "apple-quality-precondition",
                ],
                cwd=REPO,
                check=True,
            )

            receipt = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(
                ["apple-quality-precondition"],
                receipt["test_system_issue_ids"],
            )

    def test_flaky_receipt_requires_registered_issue(self):
        process, receipt = self.run_result("--test-system-status", "FLAKY")

        self.assertNotEqual(0, process.returncode)
        self.assertIsNone(receipt)
        self.assertIn("requires an active registered issue", process.stdout)

    def test_passed_test_system_cannot_carry_issue_id(self):
        process, receipt = self.run_result(
            "--test-system-status",
            "PASSED",
            "--test-system-issue-id",
            "apple-simulator-xctest-runner-launch",
        )

        self.assertNotEqual(0, process.returncode)
        self.assertIsNone(receipt)
        self.assertIn("PASSED test-system status cannot carry", process.stdout)

    def test_unknown_issue_id_is_rejected(self):
        process, receipt = self.run_result(
            "--test-system-status",
            "FAILED",
            "--test-system-issue-id",
            "unknown-issue",
        )

        self.assertNotEqual(0, process.returncode)
        self.assertIsNone(receipt)
        self.assertIn("unknown or inactive", process.stdout)

    def test_resolved_flake_issue_id_is_rejected(self):
        process, receipt = self.run_result(
            "--test-system-status",
            "FLAKY",
            "--test-system-issue-id",
            "apple-simulator-xctest-runner-launch",
        )

        self.assertNotEqual(0, process.returncode)
        self.assertIsNone(receipt)
        self.assertIn("unknown or inactive", process.stdout)


if __name__ == "__main__":
    unittest.main()
