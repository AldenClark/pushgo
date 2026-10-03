import json
import subprocess
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "quality_observation.py"


class QualityObservationTests(unittest.TestCase):
    def write_receipt(
        self,
        root: Path,
        day: int,
        lane: str,
        *,
        product: str = "PASSED",
        test_system: str = "PASSED",
        selected: list[str] | None = None,
        executed: list[str] | None = None,
        issues: list[str] | None = None,
        run_identity: str | None = None,
    ) -> None:
        recorded = datetime(2026, 8, 1, tzinfo=timezone.utc) + timedelta(days=day)
        selected_claims = selected or [f"claim-{day}"]
        executed_claims = executed if executed is not None else selected_claims
        payload = {
            "schema_version": 2,
            "recorded_at": recorded.isoformat(),
            "platform": "apple",
            "lane": lane,
            "product_capability_status": product,
            "test_system_status": test_system,
            "selected_claims": selected_claims,
            "executed_claims": executed_claims,
            "incomplete_selected_claims": [
                claim for claim in selected_claims if claim not in executed_claims
            ],
            "test_system_issue_ids": issues or [],
            "source_revision": f"revision-{day}",
            "source_dirty": False,
            "run_identity": run_identity or f"run-{day}-{lane}",
        }
        (root / f"receipt-{day:02d}-{lane}.json").write_text(json.dumps(payload), encoding="utf-8")

    def run_report(self, root: Path, *extra: str) -> tuple[subprocess.CompletedProcess[str], dict]:
        output = root / "observation.json"
        process = subprocess.run(
            [
                "python3",
                str(SCRIPT),
                "--input",
                str(root),
                "--output",
                str(output),
                "--required-lane",
                "pr",
                "--required-lane",
                "nightly",
                "--required-lane",
                "release",
                *extra,
            ],
            cwd=REPO,
            text=True,
            capture_output=True,
        )
        return process, json.loads(output.read_text())

    def test_fourteen_contiguous_days_are_only_ready_for_recorded_review(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            lanes = ["pr", "nightly", "release"]
            for day in range(14):
                self.write_receipt(root, day, lanes[day % len(lanes)])
            process, report = self.run_report(root, "--require-ready")
            self.assertEqual(0, process.returncode, process.stderr)
            self.assertEqual("READY_FOR_RECORDED_REVIEW", report["assessment_status"])
            self.assertIn("not product PASSED", report["claim_limit"])
            self.assertEqual(14, report["calendar_day_count"])
            self.assertEqual([], report["blockers"])

    def test_gap_and_incomplete_latest_lane_cannot_be_ready(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for day in range(14):
                if day == 7:
                    continue
                self.write_receipt(root, day, "nightly")
            self.write_receipt(
                root,
                14,
                "pr",
                product="FAILED",
                selected=["p0-visible-purpose"],
                executed=[],
            )
            self.write_receipt(root, 15, "release", product="NOT_RUN", test_system="BLOCKED")
            process, report = self.run_report(root, "--require-ready")
            self.assertEqual(3, process.returncode)
            self.assertEqual("INSUFFICIENT_EVIDENCE", report["assessment_status"])
            self.assertIn("latest_required_lane_not_clean:pr", report["blockers"])
            self.assertIn("latest_required_lane_not_clean:release", report["blockers"])
            self.assertTrue(report["incomplete_receipts"])
            self.assertTrue(report["non_clean_required_receipts"])

    def test_report_ignores_unrelated_json_and_does_not_consume_itself(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "unrelated.json").write_text('{"status":"PASSED"}', encoding="utf-8")
            self.write_receipt(root, 0, "pr")
            first, first_report = self.run_report(root, "--minimum-calendar-days", "1")
            second, second_report = self.run_report(root, "--minimum-calendar-days", "1")
            self.assertEqual(0, first.returncode)
            self.assertEqual(0, second.returncode)
            self.assertEqual(1, first_report["receipt_count"])
            self.assertEqual(1, second_report["receipt_count"])

    def test_focused_receipts_cannot_fill_required_lane_calendar(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for day in range(14):
                self.write_receipt(root, day, "focused")
            self.write_receipt(root, 0, "pr")
            self.write_receipt(root, 0, "nightly")
            self.write_receipt(root, 0, "release")
            process, report = self.run_report(root, "--require-ready")
            self.assertEqual(3, process.returncode)
            self.assertEqual(17, report["receipt_count"])
            self.assertEqual(3, report["observation_receipt_count"])
            self.assertEqual(1, report["observation_span_days"])

    def test_duplicate_run_identity_cannot_fabricate_two_days(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            lanes = ["pr", "nightly", "release"]
            for day in range(14):
                self.write_receipt(root, day, lanes[day % 3], run_identity="copied-run")
            process, report = self.run_report(root, "--require-ready")
            self.assertEqual(3, process.returncode)
            self.assertIn("copied-run", report["duplicate_run_identities"])
            self.assertTrue(
                any(item.startswith("duplicate_run_identities:") for item in report["blockers"])
            )

    def test_unreadable_formal_receipt_blocks_instead_of_disappearing(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "failed-run-summary.json").write_text("{", encoding="utf-8")
            output = root / "observation.json"
            process = subprocess.run(
                ["python3", str(SCRIPT), "--input", str(root), "--output", str(output)],
                cwd=REPO,
                text=True,
                capture_output=True,
            )
            self.assertEqual(2, process.returncode)
            self.assertIn("unreadable formal quality receipt", process.stdout)
            self.assertFalse(output.exists())

    def test_invalid_status_pair_and_unauthorized_waiver_are_rejected(self) -> None:
        for product, test_system in (("PASSED", "BLOCKED"), ("WAIVED", "PASSED")):
            with self.subTest(product=product, test_system=test_system):
                with tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    self.write_receipt(root, 0, "release", product=product, test_system=test_system)
                    output = root / "observation.json"
                    process = subprocess.run(
                        ["python3", str(SCRIPT), "--input", str(root), "--output", str(output)],
                        cwd=REPO,
                        text=True,
                        capture_output=True,
                    )
                    self.assertEqual(2, process.returncode)
                    self.assertIn("invalid receipt contract", process.stdout)
                    self.assertFalse(output.exists())

    def test_import_rejects_old_schema_and_passed_receipt_without_claims(self) -> None:
        for mutation in ("old-schema", "empty-claims", "non-string-waiver"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.write_receipt(root, 0, "release")
                receipt = next(root.glob("*.json"))
                payload = json.loads(receipt.read_text(encoding="utf-8"))
                if mutation == "old-schema":
                    payload["schema_version"] = 1
                elif mutation == "empty-claims":
                    payload["selected_claims"] = []
                    payload["executed_claims"] = []
                    payload["incomplete_selected_claims"] = []
                else:
                    payload["waiver_id"] = 1
                receipt.write_text(json.dumps(payload), encoding="utf-8")
                output = root / "observation.json"
                process = subprocess.run(
                    ["python3", str(SCRIPT), "--input", str(root), "--output", str(output)],
                    cwd=REPO,
                    text=True,
                    capture_output=True,
                )
                self.assertEqual(2, process.returncode)
                self.assertIn("invalid receipt contract", process.stdout)
                self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
