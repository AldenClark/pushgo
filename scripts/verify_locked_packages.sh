#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/pushgo.xcodeproj"
XCODE_LOCK="$PROJECT/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
SWIFTPM_LOCK="$ROOT/Package.resolved"

python3 - "$PROJECT/project.pbxproj" "$XCODE_LOCK" "$SWIFTPM_LOCK" <<'PY'
import json
import pathlib
import re
import sys

project_path, xcode_lock_path, swiftpm_lock_path = map(pathlib.Path, sys.argv[1:])
project = project_path.read_text(encoding="utf-8")

for forbidden in ("kind = branch;", "kind = upToNextMajorVersion;", "kind = upToNextMinorVersion;"):
    if forbidden in project:
        raise SystemExit(f"release package graph contains a floating requirement: {forbidden}")

textual_match = re.search(
    r'XCRemoteSwiftPackageReference "textual".*?requirement = \{.*?kind = revision;.*?revision = ([0-9a-f]{40});',
    project,
    flags=re.S,
)
if textual_match is None:
    raise SystemExit("Textual must use an immutable 40-character revision in project.pbxproj")

for lock_path in (xcode_lock_path, swiftpm_lock_path):
    payload = json.loads(lock_path.read_text(encoding="utf-8"))
    for pin in payload.get("pins", []):
        state = pin.get("state", {})
        if "branch" in state:
            raise SystemExit(f"{lock_path}: {pin.get('identity')} still resolves from a branch")
        revision = state.get("revision")
        if not isinstance(revision, str) or not re.fullmatch(r"[0-9a-f]{40}", revision):
            raise SystemExit(f"{lock_path}: {pin.get('identity')} lacks an immutable revision")

xcode_payload = json.loads(xcode_lock_path.read_text(encoding="utf-8"))
textual_pin = next((pin for pin in xcode_payload.get("pins", []) if pin.get("identity") == "textual"), None)
if textual_pin is None or textual_pin.get("state", {}).get("revision") != textual_match.group(1):
    raise SystemExit("Textual project requirement and Xcode Package.resolved revision differ")
PY

before_xcode="$(shasum -a 256 "$XCODE_LOCK" | awk '{print $1}')"
before_swiftpm="$(shasum -a 256 "$SWIFTPM_LOCK" | awk '{print $1}')"

xcodebuild \
  -resolvePackageDependencies \
  -project "$PROJECT" \
  -scheme PushGo-iOS \
  -onlyUsePackageVersionsFromResolvedFile \
  -disableAutomaticPackageResolution \
  -skipPackageUpdates \
  >/dev/null

(
  cd "$ROOT"
  swift package \
    --disable-automatic-resolution \
    show-dependencies \
    --format json \
    >/dev/null
)

after_xcode="$(shasum -a 256 "$XCODE_LOCK" | awk '{print $1}')"
after_swiftpm="$(shasum -a 256 "$SWIFTPM_LOCK" | awk '{print $1}')"

if [[ "$before_xcode" != "$after_xcode" || "$before_swiftpm" != "$after_swiftpm" ]]; then
  echo "Locked package verification changed a Package.resolved file" >&2
  exit 1
fi

echo "locked package graph verified"
