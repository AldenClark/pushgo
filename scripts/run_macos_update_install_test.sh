#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
results_root="$repo_root/build/quality-results/macos-update-install"
timestamp="$(date +%Y%m%d-%H%M%S)"
result_dir="$results_root/$timestamp"
derived_data="${MACOS_UPDATE_DERIVED_DATA:-$repo_root/build/.deriveddata-macos-ui}"
bundle_id="io.ethan.pushgo"
old_version="${MACOS_UPDATE_OLD_VERSION:-1.3.0}"
old_build="${MACOS_UPDATE_OLD_BUILD:-1030099}"
new_version="${MACOS_UPDATE_NEW_VERSION:-1.3.1}"
new_build="${MACOS_UPDATE_NEW_BUILD:-1030199}"
port="${MACOS_UPDATE_TEST_PORT:-48765}"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/pushgo-macos-update-install.XXXXXX")"
http_pid=""
driver="$work_dir/macos-ui-driver"
started_at="$(date +%s)"

mkdir -p "$result_dir"

cleanup() {
  local status=$?
  if [[ -n "$http_pid" ]] && kill -0 "$http_pid" 2>/dev/null; then
    kill "$http_pid" 2>/dev/null || true
    wait "$http_pid" 2>/dev/null || true
  fi
  if [[ -x "$driver" ]]; then
    "$driver" terminate "$bundle_id" >/dev/null 2>&1 || true
  fi
  if [[ -d "$work_dir" ]]; then
    find "$work_dir" -depth -delete
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

"$repo_root/scripts/require_unlocked_apple_ui_console.sh" macos_update_install
python3 "$repo_root/scripts/quality_disk_preflight.py" \
  --path "$results_root" \
  --minimum-free-bytes "${QUALITY_MIN_FREE_BYTES:-5368709120}"

xcrun swiftc \
  -framework AppKit \
  -framework ApplicationServices \
  "$repo_root/scripts/macos_ui_driver.swift" \
  -o "$driver"

if [[ "$("$driver" count "$bundle_id")" != "0" ]]; then
  echo "status=BLOCKED"
  echo "reason=pushgo_is_already_running"
  exit 2
fi
if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "status=BLOCKED"
  echo "reason=local_update_port_in_use:$port"
  exit 2
fi

openssl genpkey -algorithm ED25519 -out "$work_dir/m0"
openssl pkey -in "$work_dir/m0" -outform DER -out "$work_dir/m1"
openssl pkey -in "$work_dir/m0" -pubout -outform DER -out "$work_dir/m2"
tail -c 32 "$work_dir/m1" | base64 > "$work_dir/m3"
public_material="$(tail -c 32 "$work_dir/m2" | base64)"
[[ "$(base64 -D < "$work_dir/m3" | wc -c | tr -d ' ')" == "32" ]]
[[ "$(printf '%s' "$public_material" | base64 -D | wc -c | tr -d ' ')" == "32" ]]

printf '%s\n' \
  "#include \"$repo_root/config/PushGo-macOS-DMG-Sparkle.xcconfig\"" \
  "PUSHGO_SPARKLE_FEED_URL = http:/\$()/127.0.0.1:$port/appcast.xml" \
  "PUSHGO_SPARKLE_PUBLIC_ED_KEY = $public_material" \
  "PUSHGO_SPARKLE_SCHEDULED_CHECK_INTERVAL = 21600" \
  > "$work_dir/update-test.xcconfig"

build_version() {
  local version="$1"
  local build_number="$2"
  xcodebuild \
    -project "$repo_root/pushgo.xcodeproj" \
    -scheme PushGo-macOS-DMG \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data" \
    -xcconfig "$work_dir/update-test.xcconfig" \
    -onlyUsePackageVersionsFromResolvedFile \
    -disableAutomaticPackageResolution \
    -skipPackageUpdates \
    MARKETING_VERSION="$version" \
    CURRENT_PROJECT_VERSION="$build_number" \
    PUSHGO_DISPLAY_VERSION="v$version" \
    build 2>&1 | tee "$result_dir/build-$version.log"
}

source_app="$derived_data/Build/Products/Debug/PushGo.app"
installed_app="$work_dir/installed/PushGo.app"
feed_dir="$work_dir/feed"
mkdir -p "$work_dir/installed" "$feed_dir"

build_version "$old_version" "$old_build"
[[ -d "$source_app" ]]
ditto "$source_app" "$installed_app"

build_version "$new_version" "$new_build"
[[ -d "$source_app" ]]
new_archive="$feed_dir/PushGo-$new_version.zip"
ditto -c -k --sequesterRsrc --keepParent "$source_app" "$new_archive"
printf 'PushGo update install quality journey %s to %s.\n' "$old_version" "$new_version" \
  > "$feed_dir/PushGo-$new_version.txt"

sparkle_bin="$derived_data/SourcePackages/artifacts/sparkle/Sparkle/bin"
[[ -x "$sparkle_bin/generate_appcast" ]]
"$sparkle_bin/generate_appcast" \
  --ed-key-file "$work_dir/m3" \
  --download-url-prefix "http://127.0.0.1:$port/" \
  --embed-release-notes \
  --maximum-deltas 0 \
  -o "$feed_dir/appcast.xml" \
  "$feed_dir" 2>&1 | tee "$result_dir/generate-appcast.log"

python3 - "$feed_dir/appcast.xml" "$new_version" "$new_build" <<'PY'
import sys
import xml.etree.ElementTree as ET

path, version, build = sys.argv[1:]
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
item = ET.parse(path).getroot().find("channel/item")
if item is None:
    raise SystemExit("generated appcast has no update item")
if item.findtext("sparkle:shortVersionString", namespaces=ns) != version:
    raise SystemExit("generated appcast short version mismatch")
if item.findtext("sparkle:version", namespaces=ns) != build:
    raise SystemExit("generated appcast build version mismatch")
enclosure = item.find("enclosure")
signature_name = "{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature"
if enclosure is None or not enclosure.get(signature_name):
    raise SystemExit("generated appcast update is not EdDSA signed")
PY

python3 -m http.server "$port" --bind 127.0.0.1 --directory "$feed_dir" \
  > "$result_dir/http.log" 2>&1 &
http_pid=$!
for _ in {1..50}; do
  if curl --fail --silent "http://127.0.0.1:$port/appcast.xml" >/dev/null; then
    break
  fi
  sleep 0.1
done
curl --fail --silent "http://127.0.0.1:$port/appcast.xml" >/dev/null
curl --fail --silent --range 0-31 \
  "http://127.0.0.1:$port/$(basename "$new_archive")" >/dev/null

old_info="$installed_app/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$old_info")" == "$old_version" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$old_info")" == "$old_build" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUEnableInstallerLauncherService' "$old_info")" == "true" ]]
codesign --verify --deep --strict --verbose=2 "$installed_app" \
  > "$result_dir/codesign-verify.log" 2>&1
codesign -d --entitlements :- "$installed_app" \
  > "$result_dir/installed-entitlements.plist" 2>/dev/null
python3 - "$result_dir/installed-entitlements.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as stream:
    entitlements = plistlib.load(stream)
services = set(entitlements.get("com.apple.security.temporary-exception.mach-lookup.global-name", []))
required = {"io.ethan.pushgo-spks", "io.ethan.pushgo-spki"}
if not required.issubset(services):
    raise SystemExit(f"installed app is missing Sparkle installer mach services: {sorted(required - services)}")
PY

session_id="macos-update-install-$timestamp"
quality_payload="$(python3 - "$session_id" <<'PY'
import base64
import json
import sys

payload = {
    "schema_version": 1,
    "session_id": sys.argv[1],
    "fixture": "empty.clean",
    "faults": {},
    "allows_system_cold_launch": True,
}
print(base64.b64encode(json.dumps(payload, separators=(",", ":")).encode()).decode())
PY
)"

env \
  PUSHGO_QUALITY_SESSION_BASE64="$quality_payload" \
  PUSHGO_AUTOMATION_SKIP_PUSH_AUTHORIZATION=1 \
  PUSHGO_AUTOMATION_FORCE_FOREGROUND_APP=1 \
  open -n "$installed_app" --args \
    -ApplePersistenceIgnoreState YES \
    -AppleLanguages '(en)' \
    -AppleLocale en_US

"$driver" wait-identifier "$bundle_id" quality-runtime.ready 20
old_pid="$(pgrep -x PushGo | head -n 1)"
[[ -n "$old_pid" ]]
"$driver" click-identifier "$bundle_id" sidebar-settings 10
"$driver" wait-identifier "$bundle_id" screen.settings 10
"$driver" wait-text "$bundle_id" "v$old_version" 10
"$driver" click-identifier "$bundle_id" action.settings.check_for_updates 10
pressed_update_title="$(
  "$driver" click-title "$bundle_id" 30 \
    "Install Update" "安装更新" "安裝更新"
)"
new_pid="$(
  "$driver" wait-installed-relaunch \
    "$bundle_id" "$installed_app" "$new_version" "$old_pid" 90
)"
"$driver" wait-identifier "$bundle_id" quality-runtime.ready 20
"$driver" click-identifier "$bundle_id" sidebar-settings 10 || true
"$driver" wait-identifier "$bundle_id" screen.settings 10
"$driver" wait-text "$bundle_id" "v$new_version" 10
"$driver" dump "$bundle_id" > "$result_dir/final-accessibility.json"

finished_at="$(date +%s)"
python3 - \
  "$result_dir/evidence.json" "$old_version" "$old_build" "$new_version" "$new_build" \
  "$old_pid" "$new_pid" "$pressed_update_title" "$((finished_at - started_at))" <<'PY'
import json
import sys

(
    output,
    old_version,
    old_build,
    new_version,
    new_build,
    old_pid,
    new_pid,
    action_title,
    duration,
) = sys.argv[1:]
payload = {
    "schema_version": 1,
    "platform": "macos",
    "lane": "update-install",
    "product_status": "PASSED",
    "test_system_status": "PASSED",
    "old": {"version": old_version, "build": int(old_build), "pid": int(old_pid)},
    "new": {"version": new_version, "build": int(new_build), "pid": int(new_pid)},
    "user_action": action_title,
    "business_retries": 0,
    "duration_seconds": int(duration),
    "oracles": [
        "old version visible in Settings",
        "real Settings check-for-updates action",
        "Sparkle EdDSA download and sandbox installer",
        "installed bundle replaced at original path",
        "new process relaunched from installed path",
        "new version visible in Settings",
    ],
}
with open(output, "w", encoding="utf-8") as stream:
    json.dump(payload, stream, ensure_ascii=False, indent=2)
    stream.write("\n")
PY

echo "status=PASSED"
echo "evidence=$result_dir/evidence.json"
