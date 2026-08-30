import importlib.util
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "quality_ui_entrypoints",
    REPO / "scripts/quality_ui_entrypoints.py",
)
assert SPEC and SPEC.loader
AUDIT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIT)


class QualityUIEntrypointAuditTests(unittest.TestCase):
    def report(self, product_source: str, test_source: str, test_suffix: str = ".swift"):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            product = root / "Product.swift"
            tests = root / f"ProductTests{test_suffix}"
            product.write_text(product_source, encoding="utf-8")
            tests.write_text(test_source, encoding="utf-8")
            return AUDIT.build_report("unit", [product], [tests], root)

    def test_identifier_overlap_never_claims_semantic_product_coverage(self):
        report = self.report(
            '.accessibilityIdentifier("action.message.open")',
            'app.buttons["action.message.open"].click()',
        )

        self.assertEqual("READY_FOR_SEMANTIC_REVIEW", report["review_status"])
        self.assertEqual(
            "REFERENCE_FOUND_SEMANTIC_ORACLE_NOT_PROVEN",
            report["referenced_product_identifiers"][0]["semantic_evidence_status"],
        )
        self.assertNotIn("PASSED", str(report))
        self.assertIn("counts are not a score", report["scope_notice"])

    def test_reports_both_unreferenced_product_and_test_only_contracts(self):
        report = self.report(
            '.accessibilityIdentifier("action.message.copy")',
            'app.buttons["action.removed.open"].click()',
        )

        self.assertEqual("REVIEW_REQUIRED", report["review_status"])
        self.assertEqual(
            ["action.message.copy"],
            [item["identifier"] for item in report["unreferenced_product_identifiers"]],
        )
        self.assertEqual(
            ["action.removed.open"],
            [item["identifier"] for item in report["test_only_identifiers"]],
        )

    def test_ignores_comment_only_and_dynamic_identifiers(self):
        report = self.report(
            """
            // .accessibilityIdentifier("action.comment.only")
            /* .accessibilityIdentifier("screen.block.comment") */
            .accessibilityIdentifier("action.item.\\(id)")
            .accessibilityIdentifier("screen.messages")
            """,
            'app.otherElements["screen.messages"].exists',
        )

        self.assertEqual(1, report["product_identifier_count"])
        self.assertEqual(
            "screen.messages",
            report["referenced_product_identifiers"][0]["identifier"],
        )

    def test_shell_host_journey_counts_real_references_but_not_comments(self):
        report = self.report(
            """
            .testTag("action.delivery_guard.confirm")
            .testTag("action.message.open_url")
            .testTag("action.comment.only")
            """,
            """
            # tap_node resource "action.comment.only"
            tap_node resource "action.delivery_guard.confirm"
            tap_node resource 'action.message.open_url'
            """,
            test_suffix=".sh",
        )

        self.assertEqual(
            ["action.delivery_guard.confirm", "action.message.open_url"],
            [item["identifier"] for item in report["referenced_product_identifiers"]],
        )
        self.assertEqual(
            ["action.comment.only"],
            [item["identifier"] for item in report["unreferenced_product_identifiers"]],
        )


if __name__ == "__main__":
    unittest.main()
