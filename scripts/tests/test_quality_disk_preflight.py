import json
import subprocess
import tempfile
import unittest
from pathlib import Path

from scripts.tests.quality_registry_fixture import copy_quality_scripts_with_nonexpiring_registry


REPO = Path(__file__).resolve().parents[2]


class QualityDiskPreflightTests(unittest.TestCase):
    def test_writable_path_with_available_capacity_is_ready(self):
        with tempfile.TemporaryDirectory() as directory:
            process = subprocess.run(
                [
                    "python3",
                    str(REPO / "scripts/quality_disk_preflight.py"),
                    "--path",
                    directory,
                    "--minimum-free-bytes",
                    "0",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )

        self.assertEqual(0, process.returncode)
        self.assertIn("disk_preflight=READY", process.stdout)

    def test_impossible_capacity_blocks_before_test_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            process = subprocess.run(
                [
                    "python3",
                    str(REPO / "scripts/quality_disk_preflight.py"),
                    "--path",
                    directory,
                    "--minimum-free-bytes",
                    str(2**63 - 1),
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )

        self.assertEqual(2, process.returncode)
        self.assertIn("reason=insufficient_free_disk:", process.stdout)

    def test_lane_preflight_block_still_writes_a_trustworthy_receipt(self):
        canonical_receipt = REPO / "build/quality-results/apple-focused-summary.json"
        canonical_before = canonical_receipt.read_bytes() if canonical_receipt.exists() else None
        with tempfile.TemporaryDirectory() as directory:
            fixture = copy_quality_scripts_with_nonexpiring_registry(Path(directory) / "fixture")
            isolated_root = Path(directory) / "results"
            process = subprocess.run(
                [str(fixture / "scripts/quality_test.sh"), "focused"],
                cwd=fixture,
                env={
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "QUALITY_MIN_FREE_BYTES": str(2**63 - 1),
                    "QUALITY_RESULTS_ROOT": str(isolated_root),
                },
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )
            isolated_receipt = isolated_root / "apple-focused-summary.json"
            self.assertTrue(isolated_receipt.is_file())
            receipt = json.loads(isolated_receipt.read_text())

        self.assertEqual(2, process.returncode)
        self.assertIn("reason=insufficient_free_disk:", process.stdout)
        self.assertIn("quality_result=", process.stdout)
        self.assertEqual("NOT_RUN", receipt["product_capability_status"])
        self.assertEqual("BLOCKED", receipt["test_system_status"])
        canonical_after = canonical_receipt.read_bytes() if canonical_receipt.exists() else None
        self.assertEqual(canonical_before, canonical_after)

    def test_explicit_lane_receipt_path_is_honored(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = copy_quality_scripts_with_nonexpiring_registry(Path(directory) / "fixture")
            isolated_root = Path(directory) / "results"
            explicit_receipt = Path(directory) / "receipts/focused.json"
            process = subprocess.run(
                [str(fixture / "scripts/quality_test.sh"), "focused"],
                cwd=fixture,
                env={
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "QUALITY_MIN_FREE_BYTES": str(2**63 - 1),
                    "QUALITY_RESULTS_ROOT": str(isolated_root),
                    "QUALITY_RESULT_FILE": str(explicit_receipt),
                },
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )

            self.assertEqual(2, process.returncode)
            self.assertTrue(explicit_receipt.is_file())
            self.assertFalse((isolated_root / "apple-focused-summary.json").exists())
            receipt = json.loads(explicit_receipt.read_text())
            self.assertEqual("NOT_RUN", receipt["product_capability_status"])
            self.assertEqual("BLOCKED", receipt["test_system_status"])


if __name__ == "__main__":
    unittest.main()
