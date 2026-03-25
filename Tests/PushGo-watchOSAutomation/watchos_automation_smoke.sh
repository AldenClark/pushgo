#!/usr/bin/env bash
set -euo pipefail

PROJECT_PATH="${PROJECT_PATH:-/Users/ethan/Repo/PushGo/pushgo/pushgo.xcodeproj}"
SCHEME="${SCHEME:-PushGo-watchOS}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/pushgo-watchos-automation}"
WATCH_BUNDLE_ID="${WATCH_BUNDLE_ID:-io.ethan.pushgo.watchkitapp}"
WATCH_DEVICE_ID="${WATCH_DEVICE_ID:-0E046937-AD9E-4F90-9A53-A9120F70CBC7}"
IPHONE_DEVICE_ID="${IPHONE_DEVICE_ID:-0158DFF9-AD51-468D-883C-B55895F18052}"
EVENT_FIXTURE_PATH="${EVENT_FIXTURE_PATH:-/Users/ethan/Repo/PushGo/tools/fixtures/p2/event-lifecycle.json}"
THING_FIXTURE_PATH="${THING_FIXTURE_PATH:-/Users/ethan/Repo/PushGo/tools/fixtures/p2/rich-thing-detail.json}"
EVENT_FIXTURE_ID="${EVENT_FIXTURE_ID:-evt_p2_active_001}"
THING_FIXTURE_ID="${THING_FIXTURE_ID:-thing_p2_rich_001}"
COLD_BOOT="${COLD_BOOT:-1}"
AUTO_SHUTDOWN="${AUTO_SHUTDOWN:-1}"
BOOT_IPHONE="${BOOT_IPHONE:-0}"
RESPONSE_TIMEOUT_SECONDS="${RESPONSE_TIMEOUT_SECONDS:-25}"
CASE_RETRY_COUNT="${CASE_RETRY_COUNT:-2}"
NO_INTERACTIVE_SIGNING="${NO_INTERACTIVE_SIGNING:-1}"

BUILD_APP_PATH="${DERIVED_DATA_PATH}/Build/Products/Debug-watchsimulator/PushGoWatch.app"
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
need_cmd xcrun
need_cmd jq

cleanup() {
  set +e
  xcrun simctl terminate "$WATCH_DEVICE_ID" "$WATCH_BUNDLE_ID" >/dev/null 2>&1 || true
  if [[ "$AUTO_SHUTDOWN" == "1" ]]; then
    xcrun simctl shutdown "$WATCH_DEVICE_ID" >/dev/null 2>&1 || true
    if [[ "$BOOT_IPHONE" == "1" ]]; then
      xcrun simctl shutdown "$IPHONE_DEVICE_ID" >/dev/null 2>&1 || true
    fi
  fi
}

trap cleanup EXIT

echo "[watchos-smoke] build debug watch app"
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "platform=watchOS Simulator,id=${WATCH_DEVICE_ID}" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  EXCLUDED_ARCHS__EFFECTIVE_PLATFORM_SUFFIX_watchsimulator=x86_64 \
  "${XCODE_NO_SIGN_FLAGS[@]}" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build >/tmp/pushgo-watchos-smoke-build.log

if [[ ! -d "$BUILD_APP_PATH" ]]; then
  echo "watch app bundle missing after build: $BUILD_APP_PATH" >&2
  exit 1
fi

echo "[watchos-smoke] prepare simulators"
xcrun simctl terminate "$WATCH_DEVICE_ID" "$WATCH_BUNDLE_ID" >/dev/null 2>&1 || true
if [[ "$COLD_BOOT" == "1" ]]; then
  xcrun simctl shutdown "$WATCH_DEVICE_ID" >/dev/null 2>&1 || true
  if [[ "$BOOT_IPHONE" == "1" ]]; then
    xcrun simctl shutdown "$IPHONE_DEVICE_ID" >/dev/null 2>&1 || true
  fi
fi

echo "[watchos-smoke] boot simulators"
if [[ "$BOOT_IPHONE" == "1" ]]; then
  xcrun simctl boot "$IPHONE_DEVICE_ID" >/dev/null 2>&1 || true
fi
xcrun simctl boot "$WATCH_DEVICE_ID" >/dev/null 2>&1 || true
if [[ "$BOOT_IPHONE" == "1" ]]; then
  xcrun simctl bootstatus "$IPHONE_DEVICE_ID" -b
fi
xcrun simctl bootstatus "$WATCH_DEVICE_ID" -b

echo "[watchos-smoke] install watch app"
xcrun simctl install "$WATCH_DEVICE_ID" "$BUILD_APP_PATH"

wait_for_file() {
  local file_path="$1"
  local timeout_seconds="$2"
  local start
  start="$(date +%s)"
  while true; do
    if [[ -f "$file_path" ]]; then
      return 0
    fi
    if (( "$(date +%s)" - start >= timeout_seconds )); then
      return 1
    fi
    sleep 0.2
  done
}

wait_for_jq_true() {
  local file_path="$1"
  local jq_expr="$2"
  local timeout_seconds="$3"
  local start
  start="$(date +%s)"
  while true; do
    if [[ -f "$file_path" ]] && jq -e "$jq_expr" "$file_path" >/dev/null 2>&1; then
      return 0
    fi
    if (( "$(date +%s)" - start >= timeout_seconds )); then
      return 1
    fi
    sleep 0.2
  done
}

assert_entity_opened_event_in_events_file() {
  local runtime_root="$1"
  local entity_type="$2"
  local entity_id="$3"
  local events_path="${runtime_root}/automation-events.jsonl"
  jq -Rse \
    '
      split("\n")
      | map(select(length > 0) | fromjson?)
      | map(select(.type == "entity.opened" and .details.entity_type == "'"${entity_type}"'" and .details.entity_id == "'"${entity_id}"'"))
      | length >= 1
    ' \
    "$events_path" >/dev/null
}

run_case() {
  local case_name="$1"
  local request_payload="$2"
  local response_check="$3"
  local state_check="$4"
  local runtime_root_override="${5:-}"

  local runtime_root
  if [[ -n "$runtime_root_override" ]]; then
    runtime_root="$runtime_root_override"
    mkdir -p "$runtime_root"
  else
    runtime_root="$(mktemp -d /tmp/pushgo-watchos-smoke.${case_name}.XXXXXX)"
  fi
  local response_path="${runtime_root}/automation-response.json"
  local state_path="${runtime_root}/automation-state.json"
  local events_path="${runtime_root}/automation-events.jsonl"
  local trace_path="${runtime_root}/automation-trace.json"

  local attempt=1
  while (( attempt <= CASE_RETRY_COUNT )); do
    echo "[watchos-smoke] case=${case_name} attempt=${attempt}/${CASE_RETRY_COUNT}"
    rm -f "$response_path" "$state_path" "$events_path" "$trace_path"
    env \
      "SIMCTL_CHILD_PUSHGO_AUTOMATION_STORAGE_ROOT=${runtime_root}" \
      "SIMCTL_CHILD_PUSHGO_AUTOMATION_PROVIDER_TOKEN=watch-smoke-provider-token" \
      "SIMCTL_CHILD_PUSHGO_AUTOMATION_SKIP_PUSH_AUTHORIZATION=1" \
      "SIMCTL_CHILD_PUSHGO_AUTOMATION_RESPONSE_PATH=${response_path}" \
      "SIMCTL_CHILD_PUSHGO_AUTOMATION_STATE_PATH=${state_path}" \
      "SIMCTL_CHILD_PUSHGO_AUTOMATION_EVENTS_PATH=${events_path}" \
      "SIMCTL_CHILD_PUSHGO_AUTOMATION_TRACE_PATH=${trace_path}" \
      "SIMCTL_CHILD_PUSHGO_AUTOMATION_REQUEST=${request_payload}" \
      xcrun simctl launch --terminate-running-process "$WATCH_DEVICE_ID" "$WATCH_BUNDLE_ID" -ApplePersistenceIgnoreState YES >/dev/null

    if ! wait_for_file "$response_path" "$RESPONSE_TIMEOUT_SECONDS"; then
      if (( attempt == CASE_RETRY_COUNT )); then
        echo "response file missing for case=${case_name}" >&2
        exit 1
      fi
      xcrun simctl terminate "$WATCH_DEVICE_ID" "$WATCH_BUNDLE_ID" >/dev/null 2>&1 || true
      sleep 1
      attempt=$((attempt + 1))
      continue
    fi
    if ! wait_for_file "$state_path" "$RESPONSE_TIMEOUT_SECONDS"; then
      if (( attempt == CASE_RETRY_COUNT )); then
        echo "state file missing for case=${case_name}" >&2
        exit 1
      fi
      xcrun simctl terminate "$WATCH_DEVICE_ID" "$WATCH_BUNDLE_ID" >/dev/null 2>&1 || true
      sleep 1
      attempt=$((attempt + 1))
      continue
    fi

    if ! jq -e "$response_check" "$response_path" >/dev/null; then
      if (( attempt == CASE_RETRY_COUNT )); then
        echo "response assertion failed for case=${case_name}" >&2
        cat "$response_path" >&2
        exit 1
      fi
      xcrun simctl terminate "$WATCH_DEVICE_ID" "$WATCH_BUNDLE_ID" >/dev/null 2>&1 || true
      sleep 1
      attempt=$((attempt + 1))
      continue
    fi

    if ! wait_for_jq_true "$state_path" "$state_check" "$RESPONSE_TIMEOUT_SECONDS"; then
      if (( attempt == CASE_RETRY_COUNT )); then
        echo "state assertion failed for case=${case_name}" >&2
        cat "$state_path" >&2
        exit 1
      fi
      xcrun simctl terminate "$WATCH_DEVICE_ID" "$WATCH_BUNDLE_ID" >/dev/null 2>&1 || true
      sleep 1
      attempt=$((attempt + 1))
      continue
    fi

    if ! [[ -f "$events_path" ]] || ! [[ -s "$events_path" ]]; then
      if (( attempt == CASE_RETRY_COUNT )); then
        echo "events file missing/empty for case=${case_name}" >&2
        exit 1
      fi
      xcrun simctl terminate "$WATCH_DEVICE_ID" "$WATCH_BUNDLE_ID" >/dev/null 2>&1 || true
      sleep 1
      attempt=$((attempt + 1))
      continue
    fi

    # Prevent long-running automation app process from accumulating across cases.
    xcrun simctl terminate "$WATCH_DEVICE_ID" "$WATCH_BUNDLE_ID" >/dev/null 2>&1 || true
    return 0
  done
}

run_case \
  "nav_events" \
  '{"id":"watch-nav-events-001","plane":"command","name":"nav.switch_tab","args":{"tab":"events"}}' \
  '.ok == true and .platform == "watchos" and .state.visible_screen == "screen.events.list" and .state.active_tab == "tab.events" and .state.runtime_error_count == 0 and .state.local_store_mode != "unavailable"' \
  '.visible_screen == "screen.events.list" and .active_tab == "tab.events" and .runtime_error_count == 0 and .local_store_mode != "unavailable"'

run_case \
  "nav_things" \
  '{"id":"watch-nav-things-001","plane":"command","name":"nav.switch_tab","args":{"tab":"things"}}' \
  '.ok == true and .platform == "watchos" and .state.visible_screen == "screen.things.list" and .state.active_tab == "tab.things" and .state.runtime_error_count == 0 and .state.local_store_mode != "unavailable"' \
  '.visible_screen == "screen.things.list" and .active_tab == "tab.things" and .runtime_error_count == 0 and .local_store_mode != "unavailable"'

run_case \
  "hide_events_page" \
  '{"id":"watch-settings-events-hide-001","plane":"command","name":"settings.set_page_visibility","args":{"page":"events","enabled":"false"}}' \
  '.ok == true and .platform == "watchos" and .state.runtime_error_count == 0' \
  '.event_page_enabled == false and .runtime_error_count == 0'

run_case \
  "show_events_page" \
  '{"id":"watch-settings-events-show-001","plane":"command","name":"settings.set_page_visibility","args":{"page":"events","enabled":"true"}}' \
  '.ok == true and .platform == "watchos" and .state.runtime_error_count == 0' \
  '.event_page_enabled == true and .runtime_error_count == 0'

run_case \
  "fixture_event_import" \
  "{\"id\":\"watch-fixture-event-001\",\"plane\":\"command\",\"name\":\"fixture.import\",\"args\":{\"path\":\"${EVENT_FIXTURE_PATH}\"}}" \
  '.ok == true and .platform == "watchos" and .state.runtime_error_count == 0' \
  '.event_count >= 1 and .runtime_error_count == 0'

run_case \
  "fixture_thing_import" \
  "{\"id\":\"watch-fixture-thing-001\",\"plane\":\"command\",\"name\":\"fixture.import\",\"args\":{\"path\":\"${THING_FIXTURE_PATH}\"}}" \
  '.ok == true and .platform == "watchos" and .state.runtime_error_count == 0' \
  '.thing_count >= 1 and .runtime_error_count == 0'

SHARED_RUNTIME_ROOT="$(mktemp -d /tmp/pushgo-watchos-shared-runtime.XXXXXX)"

run_case \
  "fixture_event_import_for_entity_open" \
  "{\"id\":\"watch-fixture-event-entity-open-001\",\"plane\":\"command\",\"name\":\"fixture.import\",\"args\":{\"path\":\"${EVENT_FIXTURE_PATH}\"}}" \
  '.ok == true and .platform == "watchos" and .state.runtime_error_count == 0' \
  '.event_count >= 1 and .runtime_error_count == 0' \
  "$SHARED_RUNTIME_ROOT"

run_case \
  "entity_open_event" \
  "{\"id\":\"watch-entity-open-event-001\",\"plane\":\"command\",\"name\":\"entity.open\",\"args\":{\"entity_type\":\"event\",\"entity_id\":\"${EVENT_FIXTURE_ID}\"}}" \
  '.ok == true and .platform == "watchos" and .state.runtime_error_count == 0 and .state.opened_entity_type == "event"' \
  ".visible_screen == \"screen.event.detail\" and .opened_entity_type == \"event\" and .runtime_error_count == 0" \
  "$SHARED_RUNTIME_ROOT"
assert_entity_opened_event_in_events_file "$SHARED_RUNTIME_ROOT" "event" "$EVENT_FIXTURE_ID"

run_case \
  "fixture_thing_import_for_entity_open" \
  "{\"id\":\"watch-fixture-thing-entity-open-001\",\"plane\":\"command\",\"name\":\"fixture.import\",\"args\":{\"path\":\"${THING_FIXTURE_PATH}\"}}" \
  '.ok == true and .platform == "watchos" and .state.runtime_error_count == 0' \
  '.thing_count >= 1 and .runtime_error_count == 0' \
  "$SHARED_RUNTIME_ROOT"

run_case \
  "entity_open_thing" \
  "{\"id\":\"watch-entity-open-thing-001\",\"plane\":\"command\",\"name\":\"entity.open\",\"args\":{\"entity_type\":\"thing\",\"entity_id\":\"${THING_FIXTURE_ID}\"}}" \
  '.ok == true and .platform == "watchos" and .state.runtime_error_count == 0 and .state.opened_entity_type == "thing"' \
  ".visible_screen == \"screen.thing.detail\" and .opened_entity_type == \"thing\" and .runtime_error_count == 0" \
  "$SHARED_RUNTIME_ROOT"
assert_entity_opened_event_in_events_file "$SHARED_RUNTIME_ROOT" "thing" "$THING_FIXTURE_ID"

echo "[watchos-smoke] all cases passed"
