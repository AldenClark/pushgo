import importlib.util
import plistlib
import shutil
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "verify_update_distribution", REPO / "scripts/verify_update_distribution.py"
)
assert SPEC and SPEC.loader
VERIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY)


class UpdateDistributionContractTests(unittest.TestCase):
    def test_repository_metadata_satisfies_distribution_contract(self):
        VERIFY.validate_appcast(REPO / "release/appcast.xml")
        VERIFY.validate_app_store(REPO / "release/appstore.json")
        VERIFY.validate_update_notes(REPO / "release/update-notes")
        VERIFY.validate_macos_sparkle_install_integration(REPO)

    def test_non_https_enclosure_is_rejected(self):
        source = (REPO / "release/appcast.xml").read_text(encoding="utf-8")
        broken = source.replace('url="https://', 'url="http://', 1)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "appcast.xml"
            path.write_text(broken, encoding="utf-8")
            with self.assertRaisesRegex(VERIFY.ContractError, "HTTPS URL"):
                VERIFY.validate_appcast(path)

    def test_sandboxed_dmg_without_installer_launcher_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self._copy_sparkle_integration_files(Path(directory))
            info_path = root / "Apps/PushGo-macOS/PushGo-macOS-DMG-Info.plist"
            with info_path.open("rb") as stream:
                info = plistlib.load(stream)
            info.pop("SUEnableInstallerLauncherService")
            with info_path.open("wb") as stream:
                plistlib.dump(info, stream)
            with self.assertRaisesRegex(VERIFY.ContractError, "Installer Launcher"):
                VERIFY.validate_macos_sparkle_install_integration(root)

    def test_incomplete_sparkle_mach_services_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self._copy_sparkle_integration_files(Path(directory))
            path = root / "Apps/PushGo-macOS/pushgomac-dmg.entitlements"
            with path.open("rb") as stream:
                entitlements = plistlib.load(stream)
            entitlements[
                "com.apple.security.temporary-exception.mach-lookup.global-name"
            ] = ["$(PRODUCT_BUNDLE_IDENTIFIER)-spks"]
            with path.open("wb") as stream:
                plistlib.dump(entitlements, stream)
            with self.assertRaisesRegex(VERIFY.ContractError, "incomplete Sparkle"):
                VERIFY.validate_macos_sparkle_install_integration(root)

    def test_quoted_xcconfig_public_key_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self._copy_sparkle_integration_files(Path(directory))
            path = root / "config/PushGo-macOS-DMG-Sparkle.xcconfig"
            source = path.read_text(encoding="utf-8")
            path.write_text(
                source.replace(
                    "PUSHGO_SPARKLE_PUBLIC_ED_KEY = ",
                    'PUSHGO_SPARKLE_PUBLIC_ED_KEY = "',
                ).replace("=\n", '="\n', 1),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(VERIFY.ContractError, "literal xcconfig quotes"):
                VERIFY.validate_macos_sparkle_install_integration(root)

    def _copy_sparkle_integration_files(self, root: Path) -> Path:
        for relative in (
            "Apps/PushGo-macOS/PushGo-macOS-DMG-Info.plist",
            "Apps/PushGo-macOS/pushgomac-dmg.entitlements",
            "pushgo.xcodeproj/project.pbxproj",
            "config/PushGo-macOS-DMG-Sparkle.xcconfig",
        ):
            source = REPO / relative
            target = root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
        return root


if __name__ == "__main__":
    unittest.main()
