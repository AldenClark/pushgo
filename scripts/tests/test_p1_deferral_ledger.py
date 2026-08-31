import datetime as dt
import re
import unittest
from collections import Counter
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
DESIGN = REPO_ROOT / "design/pushgo-app-quality-testing-final-design.md"
LEDGER = REPO_ROOT / "docs/quality/p1-deferral-ledger.md"


class P1DeferralLedgerTests(unittest.TestCase):
    def design_p1_rows(self):
        rows = {}
        section = None
        for line in DESIGN.read_text().splitlines():
            heading = re.match(r"^### (25\.\d+) ", line)
            if heading:
                section = heading.group(1)
                rows.setdefault(section, [])
                continue
            if section and re.match(r"^\| P1(?: Release)? \|", line):
                title = line.split("|")[2].strip()
                rows[section].append(title)
        return rows

    def ledger_rows(self):
        rows = []
        for line in LEDGER.read_text().splitlines():
            if not re.match(r"^\| P1-[A-Z-]+ \|", line):
                continue
            cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
            self.assertEqual(8, len(cells), line)
            rows.append(cells)
        return rows

    def expand_scope(self, spec):
        section, title_range = spec.split(":", maxsplit=1)
        titles = self.design_p1_rows().get(section)
        self.assertIsNotNone(titles, f"Unknown design section {section}")
        bounds = title_range.split("..", maxsplit=1)
        start = bounds[0]
        end = bounds[-1]
        self.assertIn(start, titles, f"Unknown first capability in {spec}")
        self.assertIn(end, titles, f"Unknown last capability in {spec}")
        start_index = titles.index(start)
        end_index = titles.index(end)
        self.assertLessEqual(start_index, end_index, f"Reversed scope {spec}")
        return [(section, title) for title in titles[start_index : end_index + 1]]

    def test_every_design_p1_is_owned_exactly_once(self):
        design_rows = {
            (section, title)
            for section, titles in self.design_p1_rows().items()
            for title in titles
        }
        self.assertEqual(130, len(design_rows), "Update the ledger summary after P1 scope changes")
        referenced = []
        for row in self.ledger_rows():
            referenced.extend(self.expand_scope(row[1]))
        counts = Counter(referenced)
        self.assertEqual(design_rows, set(counts), "P1 design/ledger coverage drift")
        self.assertFalse(
            [line for line, count in counts.items() if count != 1],
            "A P1 row must belong to exactly one closure group",
        )

    def test_semantic_scopes_are_stable_and_nonempty(self):
        for row in self.ledger_rows():
            self.assertTrue(self.expand_scope(row[1]), f"{row[0]} has no P1 capability")

    def test_required_closure_fields_and_deadlines(self):
        today = dt.date.today()
        rows = self.ledger_rows()
        self.assertEqual(23, len(rows), "Update the ledger summary after regrouping")
        implemented = []
        removed = []
        for group, scope, state, evidence, owner, due, trigger, oracle in rows:
            self.assertIn(state, {"`DEFERRED`", "`IMPLEMENTED`", "`REMOVED/NA`"}, group)
            if state == "`IMPLEMENTED`":
                implemented.append(group)
                self.assertIn("build/quality-results/", evidence, group)
                self.assertRegex(evidence, r"\b\d+/\d+\b", group)
            if state == "`REMOVED/NA`":
                removed.append(group)
                self.assertIn("reachability", evidence.lower(), group)
            self.assertGreaterEqual(len(evidence), 40, group)
            self.assertTrue(owner.endswith("owner"), group)
            deadline = dt.date.fromisoformat(due)
            self.assertGreaterEqual(deadline, today, f"{group} is overdue")
            self.assertRegex(
                trigger,
                r"Focused|Nightly|Performance|Accessibility|Release",
                group,
            )
            self.assertGreaterEqual(len(oracle), 60, group)
        self.assertEqual(["P1-EXPORT"], removed)
        self.assertEqual([], implemented)

    def test_ledger_does_not_claim_product_pass(self):
        text = LEDGER.read_text()
        self.assertNotRegex(text, r"\| `PASSED` \|")
        self.assertIn("must never be summarized as whole-product `PASSED`", text)
        self.assertIn("cannot satisfy a Release gate", text)
        self.assertIn("static quality check fails", text)


if __name__ == "__main__":
    unittest.main()
