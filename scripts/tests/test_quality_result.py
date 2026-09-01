import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts import quality_result


REPO = Path(__file__).resolve().parents[2]


class QualityResultTests(unittest.TestCase):
    def test_clean_git_status_is_not_confused_with_command_failure(self):
        completed = subprocess.CompletedProcess(["git", "status"], 0, "\n", "")
        with patch.object(quality_result.subprocess, "run", return_value=completed):
            self.assertEqual(
                "",
                quality_result.git_value("status", "--porcelain", allow_empty=True),
            )

    def run_result(self, *extra, env=None):
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
                env=env,
            )
            payload = json.loads(output.read_text(encoding="utf-8")) if output.exists() else None
            return process, payload

    def test_receipt_records_ci_source_provenance(self):
        environment = os.environ.copy()
        environment.update(
            {
                "GITHUB_SHA": "abc123",
                "GITHUB_RUN_ID": "42",
                "GITHUB_RUN_ATTEMPT": "2",
                "GITHUB_JOB": "quality",
                "QUALITY_SOURCE_DIRTY": "false",
            }
        )
        process, receipt = self.run_result("--test-system-status", "PASSED", env=environment)
        self.assertEqual(0, process.returncode, process.stdout)
        self.assertEqual(2, receipt["schema_version"])
        self.assertEqual("abc123", receipt["source_revision"])
        self.assertFalse(receipt["source_dirty"])
        self.assertEqual("github:42:2:quality", receipt["run_identity"])

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

    def test_contradictory_product_and_test_system_status_is_rejected(self):
        process, receipt = self.run_result(
            "--product-status", "PASSED",
            "--test-system-status", "BLOCKED",
        )

        self.assertNotEqual(0, process.returncode)
        self.assertIsNone(receipt)
        self.assertIn("invalid product/test-system status pair", process.stdout)

    def test_waived_status_requires_version_controlled_authorization(self):
        process, receipt = self.run_result(
            "--product-status", "WAIVED",
            "--test-system-status", "PASSED",
            "--selected-claim", "waived-purpose",
        )

        self.assertNotEqual(0, process.returncode)
        self.assertIsNone(receipt)
        self.assertIn("requires a version-controlled active waiver id", process.stdout)


if __name__ == "__main__":
    unittest.main()
