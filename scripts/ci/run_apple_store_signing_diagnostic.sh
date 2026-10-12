#!/usr/bin/env bash
set -euo pipefail
umask 077

# Build-only App Store signing check. The workflow supplies existing active
# profiles and an imported temporary signing identity; this script never
# creates profiles or submits an archive. Its own temporary output is removed;
# Xcode's default DerivedData and tool logs require a disposable hosted runner.
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
source_sha="$(git rev-parse HEAD)"
receipt_dir="$repo_root/build/quality-results/apple-store-signing-diagnostic/run-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
mkdir -p "$receipt_dir"
receipt="$receipt_dir/summary.json"
phase=preflight
profile_status=NOT_RUN
archive_status=NOT_RUN
artifact_status=NOT_RUN
signature_status=NOT_RUN
cleanup_status=NOT_RUN
build_number=""
ipa_sha256=""
pkg_sha256=""
build_root=""

write_receipt() {
  local exit_code="$1"
  python3 - "$receipt" "$source_sha" "${EXPECTED_SHA:-}" "${EXPECTED_VERSION:-}" \
    "$phase" "$profile_status" "$archive_status" "$artifact_status" "$signature_status" "$cleanup_status" \
    "$build_number" "$ipa_sha256" "$pkg_sha256" "$exit_code" <<'PY'
import json
import sys
from pathlib import Path

(
    path, source_sha, requested_sha, version, phase, profiles, archives,
    artifacts, signatures, cleanup, build_number, ipa_sha256, pkg_sha256, exit_code,
) = sys.argv[1:]
payload = {
    "kind": "apple_store_signing_diagnostic",
    "source_sha": source_sha,
    "requested_sha": requested_sha,
    "version": version,
    "build_number": build_number or None,
    "profile_validation": profiles,
    "signed_archive_export": archives,
    "artifact_verification": artifacts,
    "bundle_signature_verification": signatures,
    "temporary_output_cleanup": cleanup,
    "ipa_sha256": ipa_sha256 or None,
    "pkg_sha256": pkg_sha256 or None,
    "phase": phase,
    "exit_code": int(exit_code),
    "upload_status": "NOT_RUN",
    "notarization_status": "NOT_RUN",
    "runtime_status": "NOT_RUN",
    "claim_limit": "Build-only App Store IPA/PKG check on a disposable GitHub-hosted macOS runner. Only this script's RUNNER_TEMP output is removed; default Xcode DerivedData and tool logs last until the runner is discarded. No App Store acceptance, Developer ID DMG, notarization, installation, device, or runtime test.",
}
Path(path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
PY
}

cleanup() {
  local exit_code=$?
  local cleanup_failed=0
  trap - EXIT
  set +e
  if [[ "$profile_status" == RUNNING ]]; then profile_status=FAILED; fi
  if [[ "$archive_status" == RUNNING ]]; then archive_status=FAILED; fi
  if [[ "$artifact_status" == RUNNING ]]; then artifact_status=FAILED; fi
  if [[ "$signature_status" == RUNNING ]]; then signature_status=FAILED; fi
  cleanup_status=RUNNING
  if [[ -n "$build_root" ]]; then
    rm -rf -- "$build_root" >/dev/null 2>&1 || cleanup_failed=1
  fi
  if (( cleanup_failed )); then
    echo 'Temporary signing build output could not be removed' >&2
    phase=cleanup
    cleanup_status=FAILED
    exit_code=4
  else
    cleanup_status=PASSED
  fi
  if ! write_receipt "$exit_code"; then
    echo 'Diagnostic receipt could not be written' >&2
    exit_code=4
  fi
  printf 'apple_store_signing_diagnostic phase=%s exit=%s receipt=%s\n' "$phase" "$exit_code" "$receipt"
  exit "$exit_code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    printf 'Missing required diagnostic input: %s\n' "$name" >&2
    exit 2
  fi
}

[[ "${GITHUB_ACTIONS:-}" == true ]] || { echo 'GitHub Actions runner required' >&2; exit 2; }
[[ "${RUNNER_ENVIRONMENT:-}" == github-hosted ]] || { echo 'Disposable GitHub-hosted runner required' >&2; exit 2; }
[[ "$(uname -s)" == Darwin ]] || { echo 'macOS runner required' >&2; exit 2; }
for name in RUNNER_TEMP EXPECTED_SHA EXPECTED_VERSION APPLE_TEAM_ID PROFILE_STAGE_DIR \
  RELEASE_SIGNING_KEYCHAIN_PATH APP_STORE_PROFILE_IOS_APP_UUID \
  APP_STORE_PROFILE_IOS_NSE_UUID APP_STORE_PROFILE_WATCH_APP_UUID \
  APP_STORE_PROFILE_WATCH_NSE_UUID APP_STORE_PROFILE_IOS_WIDGET_UUID \
  APP_STORE_PROFILE_WATCH_WIDGET_UUID APP_STORE_PROFILE_MACOS_APP_UUID \
  APP_STORE_PROFILE_MACOS_NSE_UUID APP_STORE_PROFILE_MACOS_WIDGET_UUID \
  APP_STORE_PROFILE_MACOS_WIDGET_NAME; do
  require_env "$name"
done
[[ "$EXPECTED_SHA" =~ ^[0-9a-f]{40}$ && "$source_sha" == "$EXPECTED_SHA" ]] || {
  echo 'Checked-out source does not match requested full SHA' >&2
  exit 2
}
[[ -z "$(git status --porcelain --untracked-files=all)" ]] || {
  echo 'Checked-out source is not clean at requested SHA' >&2
  exit 2
}
[[ "$EXPECTED_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo 'Expected version must be a stable SemVer core' >&2
  exit 2
}
[[ "$APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || { echo 'Invalid Apple team ID' >&2; exit 2; }
python3 - "$PROFILE_STAGE_DIR" "$RUNNER_TEMP" "$RELEASE_SIGNING_KEYCHAIN_PATH" <<'PY' || exit 2
import sys
from pathlib import Path

profiles, temporary, keychain = (Path(arg).resolve() for arg in sys.argv[1:])
if not profiles.is_dir():
    raise SystemExit('Selected existing profile directory is unavailable')
if not temporary.is_dir() or not keychain.is_file() or not keychain.is_relative_to(temporary):
    raise SystemExit('Selected signing keychain must exist under runner temporary storage')
PY

phase=profiles
profile_status=RUNNING
python3 - "$PROFILE_STAGE_DIR" <<'PY' || { echo 'Existing App Store profile preflight failed' >&2; exit 2; }
import datetime
import os
import plistlib
import re
import subprocess
import sys
from pathlib import Path

profile_dir = Path(sys.argv[1])
team = os.environ["APPLE_TEAM_ID"]
profiles = (
    ("ios_app", "APP_STORE_PROFILE_IOS_APP_UUID", "io.ethan.pushgo", "iOS"),
    ("ios_nse", "APP_STORE_PROFILE_IOS_NSE_UUID", "io.ethan.pushgo.NotificationServiceExtension", "iOS"),
    ("watch_app", "APP_STORE_PROFILE_WATCH_APP_UUID", "io.ethan.pushgo.watchkitapp", "iOS"),
    ("watch_nse", "APP_STORE_PROFILE_WATCH_NSE_UUID", "io.ethan.pushgo.watchkitapp.NotificationServiceExtension", "iOS"),
    ("ios_widget", "APP_STORE_PROFILE_IOS_WIDGET_UUID", "io.ethan.pushgo.widgets", "iOS"),
    ("watch_widget", "APP_STORE_PROFILE_WATCH_WIDGET_UUID", "io.ethan.pushgo.watchkitapp.widgets", "iOS"),
    ("macos_app", "APP_STORE_PROFILE_MACOS_APP_UUID", "io.ethan.pushgo", "OSX"),
    ("macos_nse", "APP_STORE_PROFILE_MACOS_NSE_UUID", "io.ethan.pushgo.NotificationServiceExtension", "OSX"),
    ("macos_widget", "APP_STORE_PROFILE_MACOS_WIDGET_UUID", "io.ethan.pushgo.macwidgets", "OSX"),
)
for label, variable, bundle, platform in profiles:
    uuid = os.environ[variable]
    if not re.fullmatch(r"[0-9A-Fa-f-]{36}", uuid):
        raise SystemExit(f"{label}: invalid selected profile UUID")
    extension = "provisionprofile" if platform == "OSX" else "mobileprovision"
    path = profile_dir / f"{uuid}.{extension}"
    try:
        raw = subprocess.run(
            ["security", "cms", "-D", "-i", str(path)],
            check=True, capture_output=True,
        ).stdout
        profile = plistlib.loads(raw)
        expiry = profile["ExpirationDate"]
        if expiry.tzinfo is None:
            expiry = expiry.replace(tzinfo=datetime.timezone.utc)
        identifier = profile["Entitlements"].get("application-identifier") or profile["Entitlements"].get("com.apple.application-identifier")
        if (
            profile["UUID"] != uuid
            or team not in profile["TeamIdentifier"]
            or identifier != f"{team}.{bundle}"
            or platform not in profile["Platform"]
            or expiry <= datetime.datetime.now(datetime.timezone.utc)
            or profile["Entitlements"].get("get-task-allow") is True
        ):
            raise ValueError("profile metadata mismatch")
        if label == "macos_widget" and profile["Name"] != os.environ["APP_STORE_PROFILE_MACOS_WIDGET_NAME"]:
            raise ValueError("selected profile name mismatch")
    except (OSError, KeyError, TypeError, ValueError, subprocess.CalledProcessError):
        raise SystemExit(f"{label}: missing, expired, or incompatible App Store profile")
PY
if ! /usr/bin/python3 scripts/validate_release_profiles.py \
  --profiles-dir "$PROFILE_STAGE_DIR" \
  --profile "iOS app:${APP_STORE_PROFILE_IOS_APP_UUID}:io.ethan.pushgo:Apps/PushGo-iOS/pushgo.entitlements" \
  --profile "iOS NSE:${APP_STORE_PROFILE_IOS_NSE_UUID}:io.ethan.pushgo.NotificationServiceExtension:Extensions/PushGoNSE-iOS/NotificationServiceExtension.entitlements" \
  --profile "watch app:${APP_STORE_PROFILE_WATCH_APP_UUID}:io.ethan.pushgo.watchkitapp:Apps/PushGo-watchOS/pushgowatch Watch App.entitlements" \
  --profile "watch NSE:${APP_STORE_PROFILE_WATCH_NSE_UUID}:io.ethan.pushgo.watchkitapp.NotificationServiceExtension:Extensions/PushGoNSE-watchOS/pushgowatch NotificationServiceExtension.entitlements" \
  --profile "iOS widget:${APP_STORE_PROFILE_IOS_WIDGET_UUID}:io.ethan.pushgo.widgets:Extensions/PushGoWidgets/PushGoWidgets.entitlements" \
  --profile "watch widget:${APP_STORE_PROFILE_WATCH_WIDGET_UUID}:io.ethan.pushgo.watchkitapp.widgets:Extensions/PushGoWidgets/PushGoWidgets-watchOS.entitlements" \
  --profile "macOS app:${APP_STORE_PROFILE_MACOS_APP_UUID}:io.ethan.pushgo:Apps/PushGo-macOS/pushgomac.entitlements" \
  --profile "macOS NSE:${APP_STORE_PROFILE_MACOS_NSE_UUID}:io.ethan.pushgo.NotificationServiceExtension:Extensions/PushGoNSE-macOS/PushgoNotificationServiceExtension.entitlements" \
  --profile "macOS widget:${APP_STORE_PROFILE_MACOS_WIDGET_UUID}:io.ethan.pushgo.macwidgets:Extensions/PushGoWidgets/PushGoWidgets-macOS.entitlements" \
  > /dev/null 2>&1; then
  echo 'Nine App Store profiles failed entitlement validation' >&2
  exit 2
fi
profile_status=PASSED

phase=archive_export
archive_status=RUNNING
build_root="$(mktemp -d "$RUNNER_TEMP/pushgo-store-build.XXXXXX")"
export PUSHGO_DISPLAY_VERSION="v$EXPECTED_VERSION"
export BUILD_OUTPUT_DIR="$build_root/artifacts"
mkdir -p "$BUILD_OUTPUT_DIR"
if ! bundle _2.5.23_ exec fastlane ios store_build > "$build_root/build.log" 2>&1; then
  echo 'Store archive/export or built-in distribution metadata check failed' >&2
  exit 3
fi
archive_status=PASSED

phase=artifact_verify
artifact_status=RUNNING
ipa="$BUILD_OUTPUT_DIR/PushGo-iOS.ipa"
pkg="$BUILD_OUTPUT_DIR/PushGo-macOS.pkg"
[[ -s "$ipa" && -s "$pkg" ]] || { echo 'Signed IPA or PKG is missing' >&2; exit 3; }
build_number="$(python3 - "$BUILD_OUTPUT_DIR" "$EXPECTED_VERSION" <<'PY'
import plistlib
import sys
from pathlib import Path

root, version = Path(sys.argv[1]), sys.argv[2]
archives = [root / "PushGo-iOS.xcarchive", root / "PushGo-macOS.xcarchive"]
found = {}
for archive in archives:
    for path in (archive / "Products" / "Applications").rglob("Info.plist"):
        with path.open("rb") as handle:
            info = plistlib.load(handle)
        bundle = info.get("CFBundleIdentifier")
        if bundle == "io.ethan.pushgo" or (archive == archives[0] and bundle == "io.ethan.pushgo.watchkitapp"):
            found[(archive.name, bundle)] = (info.get("CFBundleShortVersionString"), info.get("CFBundleVersion"))
required = {
    ("PushGo-iOS.xcarchive", "io.ethan.pushgo"),
    ("PushGo-iOS.xcarchive", "io.ethan.pushgo.watchkitapp"),
    ("PushGo-macOS.xcarchive", "io.ethan.pushgo"),
}
if set(found) != required or any(value[0] != version for value in found.values()):
    raise SystemExit("Archived iOS, watchOS, and macOS versions do not match")
builds = {value[1] for value in found.values()}
if len(builds) != 1 or not next(iter(builds)):
    raise SystemExit("Archived iOS, watchOS, and macOS build numbers differ")
print(next(iter(builds)))
PY
)" || { echo 'Archived product version/build verification failed' >&2; exit 3; }
signature_status=RUNNING
ipa_inspection="$build_root/ipa-inspection"
pkg_inspection="$build_root/pkg-inspection"
mkdir -p "$ipa_inspection"
if ! ditto -x -k "$ipa" "$ipa_inspection" >> "$build_root/build.log" 2>&1; then
  echo 'IPA inspection extraction failed' >&2
  exit 3
fi
if ! pkgutil --expand-full "$pkg" "$pkg_inspection" >> "$build_root/build.log" 2>&1; then
  echo 'PKG inspection extraction failed' >&2
  exit 3
fi
if ! python3 - "$ipa_inspection" "$pkg_inspection" "$EXPECTED_VERSION" "$build_number" "$PROFILE_STAGE_DIR" <<'PY'
import os
import plistlib
import subprocess
import sys
from pathlib import Path

ipa_root, pkg_root = map(Path, sys.argv[1:3])
version, build_number = sys.argv[3:5]
profile_stage = Path(sys.argv[5])
ios = {
    "io.ethan.pushgo": "APP_STORE_PROFILE_IOS_APP_UUID",
    "io.ethan.pushgo.NotificationServiceExtension": "APP_STORE_PROFILE_IOS_NSE_UUID",
    "io.ethan.pushgo.watchkitapp": "APP_STORE_PROFILE_WATCH_APP_UUID",
    "io.ethan.pushgo.watchkitapp.NotificationServiceExtension": "APP_STORE_PROFILE_WATCH_NSE_UUID",
    "io.ethan.pushgo.widgets": "APP_STORE_PROFILE_IOS_WIDGET_UUID",
    "io.ethan.pushgo.watchkitapp.widgets": "APP_STORE_PROFILE_WATCH_WIDGET_UUID",
}
macos = {
    "io.ethan.pushgo": "APP_STORE_PROFILE_MACOS_APP_UUID",
    "io.ethan.pushgo.NotificationServiceExtension": "APP_STORE_PROFILE_MACOS_NSE_UUID",
    "io.ethan.pushgo.macwidgets": "APP_STORE_PROFILE_MACOS_WIDGET_UUID",
}

def verify_tree(root, expected, platform):
    found = {}
    for bundle in root.rglob("*"):
        if not bundle.is_dir() or bundle.suffix not in {".app", ".appex"}:
            continue
        info_path = bundle / ("Contents/Info.plist" if platform == "macOS" else "Info.plist")
        if not info_path.is_file():
            continue
        with info_path.open("rb") as handle:
            info = plistlib.load(handle)
        identifier = info.get("CFBundleIdentifier")
        if identifier not in expected:
            continue
        if identifier in found:
            raise ValueError(f"Duplicate exported {platform} bundle: {identifier}")
        found[identifier] = bundle
        if info.get("CFBundleShortVersionString") != version or not info.get("CFBundleVersion"):
            raise ValueError(f"Exported {platform} bundle version mismatch: {identifier}")
        if identifier in {"io.ethan.pushgo", "io.ethan.pushgo.watchkitapp"} and info["CFBundleVersion"] != build_number:
            raise ValueError(f"Exported {platform} app build mismatch: {identifier}")
        checked = subprocess.run(
            ["codesign", "--verify", "--deep", "--strict", str(bundle)],
            capture_output=True,
        )
        if checked.returncode:
            raise ValueError(f"Exported {platform} bundle signature invalid: {identifier}")
        profile_path = bundle / ("Contents/embedded.provisionprofile" if platform == "macOS" else "embedded.mobileprovision")
        if not profile_path.is_file():
            raise ValueError(f"Exported {platform} bundle lacks embedded profile: {identifier}")
        decoded = subprocess.run(
            ["security", "cms", "-D", "-i", str(profile_path)],
            capture_output=True,
        )
        if decoded.returncode:
            raise ValueError(f"Exported {platform} embedded profile invalid: {identifier}")
        profile = plistlib.loads(decoded.stdout)
        selected_uuid = os.environ[expected[identifier]]
        if profile.get("UUID") != selected_uuid:
            raise ValueError(f"Exported {platform} profile selection mismatch: {identifier}")
        stage_extension = "provisionprofile" if platform == "macOS" else "mobileprovision"
        staged = subprocess.run(
            ["security", "cms", "-D", "-i", str(profile_stage / f"{selected_uuid}.{stage_extension}")],
            capture_output=True,
        )
        if staged.returncode or profile != plistlib.loads(staged.stdout):
            raise ValueError(f"Exported {platform} profile content mismatch: {identifier}")
    if set(found) != set(expected):
        raise ValueError(f"Exported {platform} bundle set incomplete")

try:
    verify_tree(ipa_root / "Payload", ios, "iOS/watchOS")
    verify_tree(pkg_root, macos, "macOS")
except (OSError, ValueError, plistlib.InvalidFileException) as error:
    raise SystemExit(str(error))
PY
then
  echo 'Exported bundle signature, version, or embedded profile verification failed' >&2
  exit 3
fi
signature_status=PASSED
ipa_sha256="$(shasum -a 256 "$ipa" | awk '{print $1}')"
pkg_sha256="$(shasum -a 256 "$pkg" | awk '{print $1}')"
artifact_status=PASSED
phase=complete
