#!/usr/bin/env python3
"""Compare unsigned macOS Release payload slices with effective Xcode ARCHS."""

from __future__ import annotations

import argparse
import json
import plistlib
import re
import subprocess
import sys
from pathlib import Path


class ArchitectureError(RuntimeError):
    pass


def build_settings_by_bundle(path: Path) -> dict[str, dict[str, object]]:
    text = path.read_text(encoding="utf-8", errors="replace")
    sections = re.split(
        r"(?=^Build settings for action build and target .+:$)", text, flags=re.MULTILINE
    )
    settings: dict[str, dict[str, object]] = {}
    for section in sections:
        heading = re.search(
            r"^Build settings for action build and target (.+):$", section, re.MULTILINE
        )
        if heading is None:
            continue
        values = dict(re.findall(r"^\s*([A-Z][A-Z0-9_]*)\s*=\s*(.*?)\s*$", section, re.MULTILINE))
        bundle_id = values.get("PRODUCT_BUNDLE_IDENTIFIER", "").strip('"')
        architectures = sorted(set(values.get("ARCHS", "").split()))
        wrapper_extension = values.get("WRAPPER_EXTENSION", "")
        if wrapper_extension == "appex" and (
            not bundle_id or not architectures or values.get("CONFIGURATION") != "Release"
        ):
            raise ArchitectureError(f"incomplete Release extension settings: {heading.group(1)}")
        if not bundle_id or not architectures or values.get("CONFIGURATION") != "Release":
            continue
        if bundle_id in settings:
            raise ArchitectureError(f"duplicate Release settings for {bundle_id}")
        settings[bundle_id] = {
            "target": heading.group(1),
            "architectures": architectures,
            "wrapper_extension": wrapper_extension,
        }
    if not settings:
        raise ArchitectureError("no per-target Release architecture settings")
    return settings


def bundle_record(bundle: Path, settings: dict[str, dict[str, object]]) -> dict[str, object]:
    plist_path = bundle / "Contents/Info.plist"
    if not plist_path.is_file():
        raise ArchitectureError(f"missing macOS bundle Info.plist: {bundle.name}")
    with plist_path.open("rb") as stream:
        info = plistlib.load(stream)
    bundle_id = info.get("CFBundleIdentifier")
    executable_name = info.get("CFBundleExecutable")
    if not isinstance(bundle_id, str) or not isinstance(executable_name, str):
        raise ArchitectureError(f"invalid macOS bundle identity: {bundle.name}")
    target = settings.get(bundle_id)
    if target is None:
        raise ArchitectureError(f"no Release ARCHS for embedded bundle {bundle_id}")
    executable = bundle / "Contents/MacOS" / executable_name
    if not executable.is_file():
        raise ArchitectureError(f"missing macOS bundle executable: {bundle_id}")
    observed = subprocess.run(
        ["/usr/bin/lipo", "-archs", str(executable)],
        capture_output=True, text=True, timeout=10, check=True,
    ).stdout.split()
    expected = target["architectures"]
    if sorted(set(observed)) != expected:
        raise ArchitectureError(
            f"{bundle_id} slices {sorted(set(observed))} differ from Release ARCHS {expected}"
        )
    return {
        "bundle_id": bundle_id,
        "target": target["target"],
        "bundle": str(bundle),
        "executable": str(executable),
        "architectures": sorted(set(observed)),
        "expected_architectures": expected,
    }


def verify(app: Path, settings_path: Path) -> dict[str, object]:
    if not app.is_dir():
        raise ArchitectureError(f"missing macOS Release app: {app}")
    settings = build_settings_by_bundle(settings_path)
    app_record = bundle_record(app, settings)
    if app_record["bundle_id"] != "io.ethan.pushgo":
        raise ArchitectureError("Release app bundle identity differs from PushGo")
    extensions = sorted(app.rglob("*.appex"))
    records = [app_record] + [bundle_record(extension, settings) for extension in extensions]
    expected_extensions = {
        bundle_id for bundle_id, target in settings.items()
        if target["wrapper_extension"] == "appex"
    }
    actual_extensions = {record["bundle_id"] for record in records[1:]}
    if expected_extensions != actual_extensions or len(actual_extensions) != len(extensions):
        raise ArchitectureError(
            f"embedded extension inventory differs from Release targets: "
            f"expected={sorted(expected_extensions)} actual={sorted(actual_extensions)}"
        )
    app_architectures = app_record["architectures"]
    return {
        "status": "PASSED",
        "architecture_scope": ",".join(app_architectures),
        "extension_count": len(extensions),
        "bundles": records,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--build-settings", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = verify(args.app, args.build_settings)
    except (ArchitectureError, OSError, ValueError, plistlib.InvalidFileException, subprocess.SubprocessError) as error:
        print(f"status=FAILED\nreason={error}", file=sys.stderr)
        return 1
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(f"status=PASSED architecture_scope={result['architecture_scope']} extensions={result['extension_count']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
