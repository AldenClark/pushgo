import plistlib
import re
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts import verify_apple_release_isolation as isolation
from scripts import verify_macos_release_architectures as macos_architectures


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

    def test_optional_macos_product_requires_unsigned_release_settings_and_real_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            settings = root / "macos-settings.log"
            settings.write_text(
                "CONFIGURATION = Release\nCODE_SIGNING_ALLOWED = NO\n"
                "SWIFT_ACTIVE_COMPILATION_CONDITIONS = \n",
                encoding="utf-8",
            )
            self.assertEqual(1, isolation.verify_settings(settings, "macOS", require_unsigned=True))
            settings.write_text("CONFIGURATION = Release\nCODE_SIGNING_ALLOWED = YES\n")
            with self.assertRaisesRegex(isolation.ContractError, "disable signing"):
                isolation.verify_settings(settings, "macOS", require_unsigned=True)

            app = root / "Build/Products/Release/PushGo.app"
            executable = app / "Contents/MacOS/PushGo"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"macOS release product")
            with (app / "Contents/Info.plist").open("wb") as output:
                plistlib.dump({"CFBundleIdentifier": "io.ethan.pushgo"}, output)
            isolation.verify_product(
                root, platform="macOS", relative_app="Release/PushGo.app",
                bundle_id="io.ethan.pushgo",
            )
            executable.unlink()
            with self.assertRaisesRegex(isolation.ContractError, "missing macOS Release executable"):
                isolation.verify_product(
                    root, platform="macOS", relative_app="Release/PushGo.app",
                    bundle_id="io.ethan.pushgo",
                )

    def test_macos_architecture_receipt_covers_app_and_embedded_extension(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            settings = root / "macos-settings.log"
            settings.write_text(
                "Build settings for action build and target PushGo-macOS:\n"
                "    ARCHS = arm64 x86_64\n"
                "    CONFIGURATION = Release\n"
                "    PRODUCT_BUNDLE_IDENTIFIER = io.ethan.pushgo\n"
                "    WRAPPER_EXTENSION = app\n"
                "Build settings for action build and target PushGo-macOS-Widgets:\n"
                "    ARCHS = arm64 x86_64\n"
                "    CONFIGURATION = Release\n"
                "    PRODUCT_BUNDLE_IDENTIFIER = io.ethan.pushgo.widgets\n"
                "    WRAPPER_EXTENSION = appex\n"
            )
            app = root / "PushGo.app"
            extension = app / "Contents/PlugIns/PushGoWidgets.appex"
            for bundle, bundle_id, executable in (
                (app, "io.ethan.pushgo", "PushGo"),
                (extension, "io.ethan.pushgo.widgets", "PushGoWidgets"),
            ):
                binary = bundle / "Contents/MacOS" / executable
                binary.parent.mkdir(parents=True)
                binary.write_bytes(b"release binary")
                with (bundle / "Contents/Info.plist").open("wb") as output:
                    plistlib.dump(
                        {"CFBundleIdentifier": bundle_id, "CFBundleExecutable": executable},
                        output,
                    )

            complete = subprocess.CompletedProcess([], 0, "arm64 x86_64\n", "")
            with patch.object(macos_architectures.subprocess, "run", return_value=complete):
                receipt = macos_architectures.verify(app, settings)
            self.assertEqual("arm64,x86_64", receipt["architecture_scope"])
            self.assertEqual(1, receipt["extension_count"])
            self.assertEqual(2, len(receipt["bundles"]))

            app_only_settings = root / "macos-app-only-settings.log"
            app_only_settings.write_text(
                settings.read_text().split("Build settings for action build and target PushGo-macOS-Widgets:")[0]
            )
            with patch.object(macos_architectures.subprocess, "run", return_value=complete):
                with self.assertRaisesRegex(macos_architectures.ArchitectureError, "no Release ARCHS"):
                    macos_architectures.verify(app, app_only_settings)

            missing_extension = root / "missing-extension"
            extension.rename(missing_extension)
            with patch.object(macos_architectures.subprocess, "run", return_value=complete):
                with self.assertRaisesRegex(macos_architectures.ArchitectureError, "inventory differs"):
                    macos_architectures.verify(app, settings)
            missing_extension.rename(extension)

            incomplete = subprocess.CompletedProcess([], 0, "arm64\n", "")
            with patch.object(macos_architectures.subprocess, "run", return_value=incomplete):
                with self.assertRaisesRegex(macos_architectures.ArchitectureError, "differ"):
                    macos_architectures.verify(app, settings)


if __name__ == "__main__":
    unittest.main()
