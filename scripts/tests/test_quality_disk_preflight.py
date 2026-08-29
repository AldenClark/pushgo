import subprocess
import tempfile
import unittest
from pathlib import Path


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
        process = subprocess.run(
            [str(REPO / "scripts/quality_test.sh"), "focused"],
            cwd=REPO,
            env={
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "QUALITY_MIN_FREE_BYTES": str(2**63 - 1),
            },
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )

        self.assertEqual(2, process.returncode)
        self.assertIn("reason=insufficient_free_disk:", process.stdout)
        self.assertIn("quality_result=", process.stdout)


if __name__ == "__main__":
    unittest.main()
