#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${RUNNER_TEMP:?Missing RUNNER_TEMP}"
: "${GITHUB_ENV:?Missing GITHUB_ENV}"
: "${APPLE_TEAM_ID:?Missing APPLE_TEAM_ID}"
: "${ASC_KEY_ID:?Missing ASC_KEY_ID}"
: "${ASC_ISSUER_ID:?Missing ASC_ISSUER_ID}"
: "${ASC_API_PRIVATE_KEY:?Missing ASC_API_PRIVATE_KEY}"

bundle_id="io.ethan.pushgo.macwidgets"
profile_name="pushgo widgets mac"
profile_output_dir="$RUNNER_TEMP/pushgo-macos-widget-profile"
api_key_json="$RUNNER_TEMP/pushgo-asc-api-key.json"
profile_filename="PushGo-macOS-widget.mobileprovision"
profile_path="$profile_output_dir/$profile_filename"
profile_plist="$RUNNER_TEMP/pushgo-macos-widget-profile.plist"
profiles_dir="$HOME/Library/MobileDevice/Provisioning Profiles"
mkdir -p "$profile_output_dir" "$profiles_dir"

cleanup() {
  rm -f "$api_key_json" "$profile_plist"
}
trap cleanup EXIT

python3 - "$api_key_json" <<'PY'
import json
import os
import pathlib
import sys

pathlib.Path(sys.argv[1]).write_text(
    json.dumps(
        {
            "key_id": os.environ["ASC_KEY_ID"],
            "issuer_id": os.environ["ASC_ISSUER_ID"],
            "key": os.environ["ASC_API_PRIVATE_KEY"],
            "in_house": False,
        }
    ),
    encoding="utf-8",
)
PY
chmod 600 "$api_key_json"

bash "$ROOT/scripts/retry_command.sh" --always -- \
  bundle _2.5.23_ exec fastlane sigh \
    --app_identifier "$bundle_id" \
    --platform macos \
    --api_key_path "$api_key_json" \
    --team_id "$APPLE_TEAM_ID" \
    --provisioning_name "$profile_name" \
    --output_path "$profile_output_dir" \
    --filename "$profile_filename"

security cms -D -i "$profile_path" > "$profile_plist"
uuid="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$profile_plist")"
name="$(/usr/libexec/PlistBuddy -c 'Print :Name' "$profile_plist")"
app_identifier="$(
  /usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$profile_plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$profile_plist"
)"
platform="$(/usr/libexec/PlistBuddy -c 'Print :Platform:0' "$profile_plist" 2>/dev/null || true)"
resolved_bundle_id="${app_identifier#*.}"

if [[ -z "$uuid" || -z "$name" ]]; then
  echo "Generated macOS widget profile metadata is incomplete" >&2
  exit 1
fi
if [[ "$resolved_bundle_id" != "$bundle_id" ]]; then
  echo "Generated macOS widget profile bundle id mismatch: ${resolved_bundle_id}" >&2
  exit 1
fi
if [[ "$platform" != "OSX" ]]; then
  echo "Generated macOS widget profile platform mismatch: ${platform:-<empty>}" >&2
  exit 1
fi

cp "$profile_path" "$profiles_dir/$uuid.provisionprofile"
{
  echo "APP_STORE_PROFILE_MACOS_WIDGET_UUID=$uuid"
  echo "APP_STORE_PROFILE_MACOS_WIDGET_NAME=$name"
} >> "$GITHUB_ENV"
echo "Installed macOS widget App Store profile ${name} (${uuid})"
