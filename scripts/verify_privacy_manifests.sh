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

python3 - "${MANIFESTS[@]}" <<'PY'
import pathlib
import plistlib
import sys

expected = {
    "NSPrivacyAccessedAPICategoryFileTimestamp": {"C617.1"},
    "NSPrivacyAccessedAPICategorySystemBootTime": {"35F9.1"},
    "NSPrivacyAccessedAPICategoryUserDefaults": {"1C8F.1", "CA92.1"},
}

for raw_path in sys.argv[1:]:
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
PY

if ! rg -q 'ProcessInfo\.processInfo\.systemUptime' "$ROOT/Apps" "$ROOT/Shared"; then
  echo "SystemBootTime reason is stale: no systemUptime use remains" >&2
  exit 1
fi
if ! rg -q 'contentModificationDate(Key)?|creationDate(Key)?|fileModificationDate' "$ROOT/Apps" "$ROOT/Shared" "$ROOT/Extensions"; then
  echo "FileTimestamp reason is stale: no covered file timestamp use remains" >&2
  exit 1
fi
if ! rg -q 'UserDefaults' "$ROOT/Apps" "$ROOT/Shared" "$ROOT/Extensions"; then
  echo "UserDefaults reasons are stale: no UserDefaults use remains" >&2
  exit 1
fi

echo "privacy manifests verified"
