import re
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]


class QualityLaneCostContractTests(unittest.TestCase):
    def test_pr_ui_is_unique_discoverable_positive_breadth(self) -> None:
        runner = (REPO / "scripts/quality_test.sh").read_text()
        test_source = (REPO / "Tests/PushGo-iOSUITests/PushGo_iOSUITests.swift").read_text()
        discovered = set(re.findall(r"func (test[A-Za-z0-9_]+)\s*\(", test_source))
        scopes = self._scopes(runner, "pr_ui_scopes")
        nightly_scopes = self._scopes(runner, "nightly_negative_ui_scopes")

        self.assertEqual(len(scopes), len(set(scopes)))
        self.assertEqual(13, len(scopes))
        self.assertEqual(len(scopes + nightly_scopes), len(set(scopes + nightly_scopes)))
        self.assertFalse(
            [scope for scope in scopes + nightly_scopes if scope.rsplit("/", 1)[-1] not in discovered]
        )
        for required_fragment in ("Messages", "PrimaryNavigation", "EventClosePersists", "Thing", "Channel", "Settings"):
            self.assertTrue(any(required_fragment in scope for scope in scopes), required_fragment)
        for deferred_fragment in ("Failure", "Corrupt", "Slow", "Delete"):
            self.assertFalse(any(deferred_fragment in scope for scope in scopes), deferred_fragment)
        self.assertFalse(any("FunctionalEmptyState" in scope for scope in scopes))
        self.assertFalse(any("MessageSearchReturnsOnly" in scope for scope in scopes))
        self.assertIn('nightly_ui_scopes="$pr_ui_scopes,$nightly_negative_ui_scopes"', runner)

    def test_real_macos_update_install_is_release_or_focused_only(self) -> None:
        runner = (REPO / "scripts/quality_test.sh").read_text()
        update_runner = (REPO / "scripts/run_macos_update_install_test.sh").read_text()

        self.assertIn("macos-update-install)\n    run_macos_update_install", runner)
        release_body = runner.split("  release)\n", 1)[1].split("  *)\n", 1)[0]
        self.assertEqual(1, release_body.count("run_macos_update_install"))
        for lane in ("pr", "nightly", "macos"):
            body = runner.split(f"  {lane})\n", 1)[1].split("    ;;", 1)[0]
            self.assertNotIn("run_macos_update_install", body)

        self.assertEqual(1, update_runner.count('click-identifier "$bundle_id" action.settings.check_for_updates'))
        self.assertEqual(1, update_runner.count('"Install Update" "安装更新" "安裝更新"'))
        self.assertIn('"business_retries": 0', update_runner)

    def _scopes(self, source: str, variable: str) -> list[str]:
        match = re.search(rf'^{variable}="([^"]+)"$', source, re.MULTILINE)
        self.assertIsNotNone(match, variable)
        return match.group(1).split(",")


if __name__ == "__main__":
    unittest.main()
