#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFESTS=(
  "$ROOT/Resources/PrivacyInfo.xcprivacy"
  "$ROOT/Apps/PushGo-watchOS/PrivacyInfo.xcprivacy"
  "$ROOT/Extensions/PushGoNSE-iOS/PrivacyInfo.xcprivacy"
  "$ROOT/Extensions/PushGoNSE-macOS/PrivacyInfo.xcprivacy"
  "$ROOT/Extensions/PushGoNSE-watchOS/PrivacyInfo.xcprivacy"
  "$ROOT/Extensions/PushGoWidgets/PrivacyInfo.xcprivacy"
)

for manifest in "${MANIFESTS[@]}"; do
  plutil -lint "$manifest" >/dev/null
done

python3 - "$ROOT" "${MANIFESTS[@]}" <<'PY'
import pathlib
import plistlib
import re
import sys

root = pathlib.Path(sys.argv[1])
expected = {
    "NSPrivacyAccessedAPICategoryFileTimestamp": {"C617.1"},
    "NSPrivacyAccessedAPICategorySystemBootTime": {"35F9.1"},
    "NSPrivacyAccessedAPICategoryUserDefaults": {"1C8F.1", "CA92.1"},
}

for raw_path in sys.argv[2:]:
    path = pathlib.Path(raw_path)
    with path.open("rb") as handle:
        payload = plistlib.load(handle)
    if payload.get("NSPrivacyTracking") is not False:
        raise SystemExit(f"{path}: tracking must remain explicitly disabled")
    declared = {
        entry.get("NSPrivacyAccessedAPIType"): set(entry.get("NSPrivacyAccessedAPITypeReasons", []))
        for entry in payload.get("NSPrivacyAccessedAPITypes", [])
    }
    if declared != expected:
        raise SystemExit(f"{path}: required-reason declarations differ from the reviewed source inventory")

source = "\n".join(
    path.read_text(encoding="utf-8", errors="ignore")
    for directory in (root / "Apps", root / "Shared", root / "Extensions")
    for path in directory.rglob("*.swift")
)
required_usage = {
    "SystemBootTime": r"ProcessInfo\.processInfo\.systemUptime",
    "FileTimestamp": r"contentModificationDate(?:Key)?|creationDate(?:Key)?|fileModificationDate",
    "UserDefaults": r"UserDefaults",
}
for category, pattern in required_usage.items():
    if re.search(pattern, source) is None:
        raise SystemExit(f"{category} reason is stale: no covered source use remains")
PY

echo "privacy manifests verified"
