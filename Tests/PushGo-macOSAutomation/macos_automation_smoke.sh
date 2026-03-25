#!/usr/bin/env bash
set -euo pipefail

PROJECT_PATH="${PROJECT_PATH:-/Users/ethan/Repo/PushGo/pushgo/pushgo.xcodeproj}"
SCHEME="${SCHEME:-PushGo-macOS}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/pushgo-macos-automation}"
HELPER_PATH="${HELPER_PATH:-/Users/ethan/Repo/PushGo/tools/pushgo_automation.py}"
EVENT_FIXTURE_PATH="${EVENT_FIXTURE_PATH:-/Users/ethan/Repo/PushGo/tools/fixtures/p2/event-lifecycle.json}"
EVENT_FIXTURE_ID="${EVENT_FIXTURE_ID:-evt_p2_active_001}"
THING_FIXTURE_PATH="${THING_FIXTURE_PATH:-/Users/ethan/Repo/PushGo/tools/fixtures/p2/rich-thing-detail.json}"
THING_FIXTURE_ID="${THING_FIXTURE_ID:-thing_p2_rich_001}"
NO_INTERACTIVE_SIGNING="${NO_INTERACTIVE_SIGNING:-1}"
MACOS_BRIDGE_ROOT="${PUSHGO_AUTOMATION_MACOS_BRIDGE_ROOT:-/tmp/pushgo-macos-automation-bridge}"

APP_BUNDLE_PATH="${DERIVED_DATA_PATH}/Build/Products/Debug/PushGo.app"
APP_EXE_PATH="${APP_BUNDLE_PATH}/Contents/MacOS/PushGo"
WORK_DIR="$(mktemp -d /tmp/pushgo-macos-smoke.XXXXXX)"
XCODE_NO_SIGN_FLAGS=()
if [[ "$NO_INTERACTIVE_SIGNING" == "1" ]]; then
  XCODE_NO_SIGN_FLAGS+=(
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
    CODE_SIGN_IDENTITY=
  )
fi

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

need_cmd xcodebuild
need_cmd python3
need_cmd jq

cleanup() {
  set +e
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

echo "[macos-smoke] build debug macOS app"
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "platform=macOS" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  "${XCODE_NO_SIGN_FLAGS[@]}" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build >/tmp/pushgo-macos-smoke-build.log

if [[ ! -x "$APP_EXE_PATH" ]]; then
  echo "missing macOS executable: $APP_EXE_PATH" >&2
  exit 1
fi

run_case_ok() {
  local case_name="$1"
  shift
  local output_path="${WORK_DIR}/${case_name}.json"
  echo "[macos-smoke] case=${case_name}"
  PUSHGO_AUTOMATION_MACOS_BRIDGE_ROOT="$MACOS_BRIDGE_ROOT" \
    python3 "$HELPER_PATH" "$@" >"$output_path"
  jq -e '.response.ok == true' "$output_path" >/dev/null
  jq -e '.state.runtime_error_count == 0' "$output_path" >/dev/null
  jq -e '.state.local_store_mode != "unavailable"' "$output_path" >/dev/null
}

run_case_fail() {
  local case_name="$1"
  shift
  local output_path="${WORK_DIR}/${case_name}.json"
  echo "[macos-smoke] case=${case_name}"
  set +e
  PUSHGO_AUTOMATION_MACOS_BRIDGE_ROOT="$MACOS_BRIDGE_ROOT" \
    python3 "$HELPER_PATH" "$@" >"$output_path"
  local exit_code=$?
  set -e
  if [[ "$exit_code" -eq 0 ]]; then
    echo "expected failure but command succeeded for case=${case_name}" >&2
    cat "$output_path" >&2
    exit 1
  fi
  jq -e '.response.ok == false' "$output_path" >/dev/null
}

assert_entity_opened_event() {
  local output_path="$1"
  local entity_type="$2"
  local entity_id="$3"
  jq -e \
    '.events
    | map(select(.type == "entity.opened" and .details.entity_type == "'"${entity_type}"'" and .details.entity_id == "'"${entity_id}"'"))
    | length >= 1' \
    "$output_path" >/dev/null
}

run_case_ok \
  "nav_channels" \
  run macos \
  --exe "$APP_EXE_PATH" \
  --name nav.switch_tab \
  --arg tab=channels \
  --wait-condition '{"eq":["visible_screen","screen.channels"]}' \
  --wait-timeout-seconds 20
jq -e '.state.visible_screen == "screen.channels"' "${WORK_DIR}/nav_channels.json" >/dev/null

run_case_ok \
  "hide_events_page" \
  run macos \
  --exe "$APP_EXE_PATH" \
  --name settings.set_page_visibility \
  --arg page=events \
  --arg enabled=false \
  --wait-condition '{"eq":["event_page_enabled",false]}' \
  --wait-timeout-seconds 20
jq -e '.state.event_page_enabled == false' "${WORK_DIR}/hide_events_page.json" >/dev/null

run_case_ok \
  "show_events_page" \
  run macos \
  --exe "$APP_EXE_PATH" \
  --name settings.set_page_visibility \
  --arg page=events \
  --arg enabled=true \
  --wait-condition '{"eq":["event_page_enabled",true]}' \
  --wait-timeout-seconds 20
jq -e '.state.event_page_enabled == true' "${WORK_DIR}/show_events_page.json" >/dev/null

run_case_ok \
  "set_decryption_key_base64" \
  run macos \
  --exe "$APP_EXE_PATH" \
  --name settings.set_decryption_key \
  --arg key=MDEyMzQ1Njc4OWFiY2RlZg== \
  --arg encoding=base64 \
  --wait-condition '{"all":[{"eq":["notification_key_configured",true]},{"eq":["notification_key_encoding","base64"]}]}' \
  --wait-timeout-seconds 20
jq -e '.state.notification_key_configured == true and .state.notification_key_encoding == "base64"' "${WORK_DIR}/set_decryption_key_base64.json" >/dev/null

run_case_fail \
  "set_decryption_key_invalid" \
  run macos \
  --exe "$APP_EXE_PATH" \
  --name settings.set_decryption_key \
  --arg key=abcd \
  --arg encoding=plain \
  --response-timeout-seconds 20
jq -e '.response.error | tostring | contains("key")' "${WORK_DIR}/set_decryption_key_invalid.json" >/dev/null

run_case_ok \
  "fixture_import_event" \
  run macos \
  --exe "$APP_EXE_PATH" \
  --name fixture.import \
  --arg "path=${EVENT_FIXTURE_PATH}" \
  --wait-condition '{"gte":["event_count",1]}' \
  --wait-timeout-seconds 20
jq -e '.state.event_count >= 1' "${WORK_DIR}/fixture_import_event.json" >/dev/null
jq -e '.state.last_fixture_import_path | tostring | contains("event-lifecycle")' "${WORK_DIR}/fixture_import_event.json" >/dev/null

SHARED_RUNTIME_DIR="${WORK_DIR}/runtime-shared"
mkdir -p "$SHARED_RUNTIME_DIR"

run_case_ok \
  "fixture_import_event_for_entity_open" \
  run macos \
  --exe "$APP_EXE_PATH" \
  --runtime-dir "$SHARED_RUNTIME_DIR" \
  --name fixture.import \
  --arg "path=${EVENT_FIXTURE_PATH}" \
  --wait-condition '{"gte":["event_count",1]}' \
  --wait-timeout-seconds 20

run_case_ok \
  "entity_open_event" \
  run macos \
  --exe "$APP_EXE_PATH" \
  --runtime-dir "$SHARED_RUNTIME_DIR" \
  --name entity.open \
  --arg entity_type=event \
  --arg "entity_id=${EVENT_FIXTURE_ID}" \
  --wait-condition '{"all":[{"eq":["visible_screen","screen.events.detail"]},{"eq":["opened_entity_type","event"]}]}' \
  --wait-timeout-seconds 20
assert_entity_opened_event "${WORK_DIR}/entity_open_event.json" "event" "${EVENT_FIXTURE_ID}"

run_case_ok \
  "fixture_import_thing_for_entity_open" \
  run macos \
  --exe "$APP_EXE_PATH" \
  --runtime-dir "$SHARED_RUNTIME_DIR" \
  --name fixture.import \
  --arg "path=${THING_FIXTURE_PATH}" \
  --wait-condition '{"gte":["thing_count",1]}' \
  --wait-timeout-seconds 20

run_case_ok \
  "entity_open_thing" \
  run macos \
  --exe "$APP_EXE_PATH" \
  --runtime-dir "$SHARED_RUNTIME_DIR" \
  --name entity.open \
  --arg entity_type=thing \
  --arg "entity_id=${THING_FIXTURE_ID}" \
  --wait-condition '{"all":[{"eq":["visible_screen","screen.things.detail"]},{"eq":["opened_entity_type","thing"]}]}' \
  --wait-timeout-seconds 20
assert_entity_opened_event "${WORK_DIR}/entity_open_thing.json" "thing" "${THING_FIXTURE_ID}"

echo "[macos-smoke] all cases passed"
