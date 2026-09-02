import re
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]


class AppleReleaseIsolationLaneTests(unittest.TestCase):
    def test_standalone_lane_is_host_only_and_full_release_reuses_the_same_check(self) -> None:
        runner = (REPO / "scripts/quality_test.sh").read_text(encoding="utf-8")
        helper = runner.split("run_release_isolation_checks() {", 1)[1].split("\n}\n", 1)[0]
        self.assertIn("xcodebuild", helper)
        self.assertIn("verify_apple_release_isolation.py", helper)
        self.assertIn("-derivedDataPath", helper)
        for forbidden in (
            "run_ios_ui_tests.sh",
            "run_macos_ui_tests.sh",
            "run_watchos_ui_tests.sh",
            "run_macos_update_install_test.sh",
            "run_system_notification_journey",
        ):
            self.assertNotIn(forbidden, helper)

        standalone = re.search(
            r"  release-isolation\)\n(?P<body>.*?)\n    ;;",
            runner,
            re.DOTALL,
        )
        self.assertIsNotNone(standalone)
        self.assertIn("run_release_isolation", standalone.group("body"))
        full_release = re.search(r"  release\)\n(?P<body>.*?)\n    ;;", runner, re.DOTALL)
        self.assertIsNotNone(full_release)
        self.assertIn("run_release_isolation", full_release.group("body"))
        self.assertNotIn("-scheme PushGo-iOS", full_release.group("body"))

    def test_verifier_requires_release_products_settings_and_compile_time_guards(self) -> None:
        verifier = (REPO / "scripts/verify_apple_release_isolation.py").read_text(encoding="utf-8")
        for required in (
            "CONFIGURATION\\s*=\\s*Release",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS",
            "GCC_PREPROCESSOR_DEFINITIONS",
            "Release-iphonesimulator/PushGo.app",
            "Release-watchsimulator/PushGoWatch.app",
            "io.ethan.pushgo",
            "io.ethan.pushgo.watchkitapp",
            "private static func resolveProcessQualitySession()",
            "WatchQualityRuntime.swift",
            "#if DEBUG",
            "#endif",
        ):
            self.assertIn(required, verifier)


if __name__ == "__main__":
    unittest.main()
