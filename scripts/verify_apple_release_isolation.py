#!/usr/bin/env python3
"""Verify the narrow, host-only Apple Release isolation contract.

This checker deliberately does not claim that a Release app is functionally
validated. It verifies the requested Release SDK products and that App-owned
quality-runtime entry points remain excluded from non-Debug builds. The macOS
product is optional for the existing formal iOS/watchOS isolation lane.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from plistlib import InvalidFileException, load as load_plist


class ContractError(RuntimeError):
    """Raised when a Release isolation precondition is not satisfied."""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--ios-derived-data", type=Path, required=True)
    parser.add_argument("--watch-derived-data", type=Path, required=True)
    parser.add_argument("--ios-build-settings", type=Path, required=True)
    parser.add_argument("--watch-build-settings", type=Path, required=True)
    parser.add_argument("--macos-derived-data", type=Path)
    parser.add_argument("--macos-build-settings", type=Path)
    parser.add_argument("--output", type=Path)
    return parser.parse_args()


def require_file(path: Path, description: str) -> Path:
    if not path.is_file():
        raise ContractError(f"missing {description}: {path}")
    return path


def verify_settings(path: Path, platform: str, *, require_unsigned: bool = False) -> int:
    text = require_file(path, f"{platform} Release build settings").read_text(
        encoding="utf-8", errors="replace"
    )
    if not re.search(r"^\s*CONFIGURATION\s*=\s*Release\s*$", text, re.MULTILINE):
        raise ContractError(f"{platform} build settings do not report CONFIGURATION = Release")

    inspected = 0
    setting_pattern = re.compile(
        r"^\s*(SWIFT_ACTIVE_COMPILATION_CONDITIONS|GCC_PREPROCESSOR_DEFINITIONS)\s*=\s*(.*?)\s*$",
        re.MULTILINE,
    )
    for match in setting_pattern.finditer(text):
        inspected += 1
        if re.search(r"(?<![A-Za-z0-9_])DEBUG(?![A-Za-z0-9_])", match.group(2)):
            raise ContractError(
                f"{platform} Release build settings enable DEBUG: {match.group(0).strip()}"
            )
    if require_unsigned:
        signing_values = re.findall(
            r"^\s*CODE_SIGNING_ALLOWED\s*=\s*(.*?)\s*$", text, re.MULTILINE
        )
        if not signing_values or any(value != "NO" for value in signing_values):
            raise ContractError(f"{platform} Release build settings do not disable signing")
    return inspected


def verify_product(derived_data: Path, *, platform: str, relative_app: str, bundle_id: str) -> None:
    app = derived_data / "Build" / "Products" / relative_app
    if not app.is_dir():
        raise ContractError(f"missing {platform} Release app: {app}")
    if platform == "macOS":
        executable = app / "Contents/MacOS/PushGo"
        plist_relative = "Contents/Info.plist"
    else:
        executable = app / ("PushGo" if platform == "iOS" else "PushGoWatch")
        plist_relative = "Info.plist"
    require_file(executable, f"{platform} Release executable")
    plist_path = require_file(app / plist_relative, f"{platform} Release Info.plist")
    try:
        with plist_path.open("rb") as stream:
            plist = load_plist(stream)
    except (InvalidFileException, OSError) as error:
        raise ContractError(f"cannot read {platform} Release Info.plist: {error}") from error
    if plist.get("CFBundleIdentifier") != bundle_id:
        raise ContractError(
            f"{platform} Release bundle id mismatch: {plist.get('CFBundleIdentifier')!r}"
        )


def verify_source_guards(source_root: Path) -> int:
    constants = require_file(
        source_root / "Shared/Utilities/AppConstants.swift",
        "AppConstants.swift",
    ).read_text(encoding="utf-8")
    def scoped_block(start: str, end: str, description: str) -> str:
        pattern = re.escape(start) + r"(?P<body>.*?)" + re.escape(end)
        match = re.search(pattern, constants, re.DOTALL)
        if not match:
            raise ContractError(f"AppConstants Release guard is missing {description}")
        return match.group("body")

    def require_fragment(text: str, fragment: str, description: str) -> None:
        if fragment not in text:
            raise ContractError(f"AppConstants Release guard is missing {description}: {fragment!r}")

    session_block = scoped_block(
        "    private static func resolveProcessQualitySession() -> ProcessQualitySessionResolution {",
        "\n    private static func qualityColdLaunchLeaseURL(",
        "the process-session resolver block",
    )
    for fragment, description in (
        ("#if DEBUG", "the Debug session branch"),
        ("let explicitSession = normalizedString(for: qualitySessionEnv)", "the explicit session input"),
        ("#else", "the non-Debug session branch"),
        (
            'return ProcessQualitySessionResolution(encodedSession: nil, inputStatus: "missing")',
            "the non-Debug missing-session result",
        ),
        ("#endif", "the session guard terminator"),
    ):
        require_fragment(session_block, fragment, description)

    storage_block = scoped_block(
        "    static var storageRootURL: URL? {",
        "\n\n    static var runtimeProfile:",
        "the storage-root resolver block",
    )
    for fragment, description in (
        ("#if DEBUG", "the Debug storage branch"),
        ("return normalizedURL(for: storageRootEnv)", "the Debug storage-root input"),
        ("#else", "the non-Debug storage branch"),
        ("return nil", "the non-Debug storage result"),
        ("#endif", "the storage guard terminator"),
    ):
        require_fragment(storage_block, fragment, description)

    active_block = scoped_block(
        "    static var isActive: Bool {",
        "\n\n    static var forceForegroundApp:",
        "the automation-active resolver block",
    )
    for fragment, description in (
        ("#if DEBUG", "the Debug active-state branch"),
        ("qualitySession != nil", "the quality-session activity check"),
        ("storageRootURL != nil", "the storage-root activity check"),
        ("providerToken != nil", "the provider-token activity check"),
        ("gatewayBaseURLString != nil", "the gateway activity check"),
        ("#else", "the non-Debug active-state branch"),
        ("false", "the non-Debug inactive result"),
        ("#endif", "the active-state guard terminator"),
    ):
        require_fragment(active_block, fragment, description)

    watch_runtime = require_file(
        source_root / "Apps/PushGo-watchOS/WatchQualityRuntime.swift",
        "watchOS quality runtime source",
    ).read_text(encoding="utf-8")
    if not watch_runtime.lstrip().startswith("#if DEBUG"):
        raise ContractError("watchOS quality runtime is not enclosed by a leading #if DEBUG")
    if not watch_runtime.rstrip().endswith("#endif"):
        raise ContractError("watchOS quality runtime is not closed by #endif")
    return 5 + 5 + 8 + 2


def verify(args: argparse.Namespace) -> dict[str, int | str]:
    if (args.macos_derived_data is None) != (args.macos_build_settings is None):
        raise ContractError("macOS derived data and Release build settings must be supplied together")
    ios_settings = verify_settings(args.ios_build_settings, "iOS")
    watch_settings = verify_settings(args.watch_build_settings, "watchOS")
    macos_settings = (
        verify_settings(args.macos_build_settings, "macOS", require_unsigned=True)
        if args.macos_build_settings is not None else None
    )
    verify_product(
        args.ios_derived_data,
        platform="iOS",
        relative_app="Release-iphonesimulator/PushGo.app",
        bundle_id="io.ethan.pushgo",
    )
    verify_product(
        args.watch_derived_data,
        platform="watchOS",
        relative_app="Release-watchsimulator/PushGoWatch.app",
        bundle_id="io.ethan.pushgo.watchkitapp",
    )
    if args.macos_derived_data is not None:
        verify_product(
            args.macos_derived_data,
            platform="macOS",
            relative_app="Release/PushGo.app",
            bundle_id="io.ethan.pushgo",
        )
    source_checks = verify_source_guards(args.source_root)
    result: dict[str, int | str] = {
        "ios_build_settings_entries": ios_settings,
        "watchos_build_settings_entries": watch_settings,
        "source_guard_checks": source_checks,
        "ios_app": str(
            args.ios_derived_data / "Build/Products/Release-iphonesimulator/PushGo.app"
        ),
        "watchos_app": str(
            args.watch_derived_data / "Build/Products/Release-watchsimulator/PushGoWatch.app"
        ),
    }
    if args.macos_derived_data is not None and macos_settings is not None:
        result["macos_build_settings_entries"] = macos_settings
        result["macos_app"] = str(
            args.macos_derived_data / "Build/Products/Release/PushGo.app"
        )
    return result


def main() -> int:
    args = parse_args()
    try:
        result = verify(args)
    except (ContractError, OSError, UnicodeError) as error:
        print(f"status=FAILED\nreason={error}", file=sys.stderr)
        return 1
    print("status=PASSED")
    print(" ".join(f"{key}={value}" for key, value in result.items()))
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(
            json.dumps({"status": "PASSED", **result}, indent=2) + "\n",
            encoding="utf-8",
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
