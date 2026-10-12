#!/usr/bin/env python3
"""Verify the intentional split between App Store and direct macOS signing."""

from __future__ import annotations

import pathlib
import plistlib
import re


ROOT = pathlib.Path(__file__).resolve().parents[1]


def require(errors: list[str], condition: bool, message: str) -> None:
    if not condition:
        errors.append(message)


def registered_url_schemes(path: pathlib.Path) -> set[str]:
    with path.open("rb") as stream:
        metadata = plistlib.load(stream)
    return {
        scheme
        for entry in metadata.get("CFBundleURLTypes", [])
        for scheme in entry.get("CFBundleURLSchemes", [])
        if isinstance(scheme, str)
    }


def main() -> int:
    errors: list[str] = []
    project = (ROOT / "pushgo.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
    fastfile = (ROOT / "fastlane/Fastfile").read_text(encoding="utf-8")
    workflow = (ROOT / ".github/workflows/apple-release.yml").read_text(encoding="utf-8")
    profile_helper = (ROOT / "scripts/ensure_macos_widget_app_store_profile.sh").read_text(
        encoding="utf-8"
    )

    for relative_path in (
        "config/PushGo-macOS-Info.plist",
        "Apps/PushGo-macOS/PushGo-macOS-DMG-Info.plist",
    ):
        require(
            errors,
            "pushgo" in registered_url_schemes(ROOT / relative_path),
            f"{relative_path} must register pushgo so system routes can reach the App",
        )

    require(
        errors,
        project.count('PRODUCT_BUNDLE_IDENTIFIER = "$(PUSHGO_MACOS_WIDGET_BUNDLE_ID)";') == 2,
        "macOS widget target must consume the distribution-specific bundle-id setting",
    )
    require(
        errors,
        project.count("PUSHGO_MACOS_WIDGET_BUNDLE_ID = io.ethan.pushgo.macwidgets;") == 2,
        "macOS widget target must default to the App Store-compatible identifier",
    )
    require(
        errors,
        'PROVISIONING_PROFILE_SPECIFIER = "$(PUSHGO_MACOS_WIDGET_PROFILE_SPECIFIER)";' in project,
        "macOS widget target must accept the profile name created by the release workflow",
    )
    require(
        errors,
        'direct_widget_bundle_setting = "PUSHGO_MACOS_WIDGET_BUNDLE_ID=io.ethan.pushgo.widgets.mac"'
        in fastfile,
        "direct DMG builds must override the widget identifier to match the Developer ID profile",
    )
    require(
        errors,
        fastfile.count('"io.ethan.pushgo.macwidgets" =>') == 2,
        "App Store entitlement and provisioning maps must use io.ethan.pushgo.macwidgets",
    )
    require(
        errors,
        fastfile.count('"io.ethan.pushgo.widgets.mac" =>') == 2,
        "direct-distribution entitlement and provisioning maps must use io.ethan.pushgo.widgets.mac",
    )
    require(
        errors,
        'PUSHGO_MACOS_WIDGET_PROFILE_SPECIFIER=#{Shellwords.escape(env_value!("APP_STORE_PROFILE_MACOS_WIDGET_NAME"))}'
        in fastfile,
        "macOS App Store archive must select the actual generated widget profile name",
    )

    release_upload = re.search(
        r"def upload_release_artifacts!.*?\n  end",
        fastfile,
        flags=re.DOTALL,
    )
    require(errors, release_upload is not None, "stable App Store upload function is missing")
    if release_upload is not None:
        require(
            errors,
            "app_store_build_selection_options(include_build_number: false)" in release_upload.group(),
            "fresh App Store binary uploads must not pass deliver's conflicting build_number option",
        )
    require(
        errors,
        "{ skip_binary_upload: true, build_number: selection[:build_number] }" in fastfile,
        "existing App Store builds must select the exact build while skipping duplicate binary upload",
    )

    require(
        errors,
        "APP_STORE_PROFILE_MACOS_WIDGET_BASE64" not in workflow,
        "App Store workflow must not reuse the direct-distribution widget profile secret",
    )
    require(
        errors,
        "- name: Ensure macOS widget App Store profile" in workflow
        and "bash ./scripts/ensure_macos_widget_app_store_profile.sh" in workflow
        and 'bundle_id="io.ethan.pushgo.macwidgets"' in profile_helper
        and "bundle _2.5.23_ exec fastlane sigh" in profile_helper,
        "App Store workflow must create or reuse the macwidgets App Store profile",
    )
    require(
        errors,
        "macOS widget:${APP_STORE_PROFILE_MACOS_WIDGET_UUID}:io.ethan.pushgo.macwidgets" in workflow,
        "App Store profile validation must require io.ethan.pushgo.macwidgets",
    )
    require(
        errors,
        "macOS direct widget:${DEVELOPER_ID_PROFILE_MACOS_WIDGET_UUID}:io.ethan.pushgo.widgets.mac"
        in workflow,
        "direct profile validation must require io.ethan.pushgo.widgets.mac",
    )

    if errors:
        raise SystemExit("\n".join(errors))
    print("release distribution identifiers and retry behavior verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
