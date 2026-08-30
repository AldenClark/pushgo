import re
import unittest
from collections import Counter
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
DESIGN = REPO_ROOT / "design/pushgo-app-quality-testing-final-design.md"
AUDIT = REPO_ROOT / "docs/quality/section-25-p0-semantic-audit.md"


class Section25P0AuditContractTest(unittest.TestCase):
    def test_every_design_p0_row_has_exactly_one_audit_row(self):
        design_rows = {
            str(line_number)
            for line_number, line in enumerate(DESIGN.read_text().splitlines(), start=1)
            if line.startswith("| P0")
        }
        audit_rows = []
        for line in AUDIT.read_text().splitlines():
            match = re.match(r"^\| (1[2-5]\d{2}) \|", line)
            if match:
                audit_rows.append(match.group(1))

        self.assertEqual(103, len(design_rows), "review new design P0 rows before changing this contract")
        self.assertEqual(len(audit_rows), len(set(audit_rows)), "audit contains duplicate design rows")
        self.assertEqual(design_rows, set(audit_rows))

    def test_audit_states_and_summary_are_structurally_consistent(self):
        states = []
        for line in AUDIT.read_text().splitlines():
            if not re.match(r"^\| 1[2-5]\d{2} \|", line):
                continue
            cells = [cell.strip() for cell in line.strip("|").split("|")]
            self.assertEqual(5, len(cells), line)
            self.assertRegex(cells[2], r"^(?:V|P|B|N|NA|-)/(?:V|P|B|N|NA|-)/(?:V|P|B|N|NA|-)/(?:V|P|B|N|NA|-)$")
            self.assertIn(cells[3], {"`V`", "`P`", "`B`", "`N`", "`NA`"})
            self.assertTrue(cells[4], "purpose-level evidence or a precise closure gap is required")
            states.append(cells[3].strip("`"))

        self.assertEqual(Counter({"V": 80, "P": 14, "N": 8, "NA": 1}), Counter(states))


if __name__ == "__main__":
    unittest.main()
