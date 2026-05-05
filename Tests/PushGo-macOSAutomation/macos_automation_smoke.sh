#!/usr/bin/env bash
set -euo pipefail

PROJECT_PATH="${PROJECT_PATH:-/Users/ethan/Repo/PushGo/pushgo/pushgo.xcodeproj}"
SCHEME="${SCHEME:-PushGo-macOS}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/pushgo-macos-automation}"
EVENT_FIXTURE_PATH="${EVENT_FIXTURE_PATH:-/Users/ethan/Repo/PushGo/pushgo/Tests/Fixtures/p2/event-lifecycle.json}"
EVENT_FIXTURE_ID="${EVENT_FIXTURE_ID:-evt_p2_active_001}"
THING_FIXTURE_PATH="${THING_FIXTURE_PATH:-/Users/ethan/Repo/PushGo/pushgo/Tests/Fixtures/p2/rich-thing-detail.json}"
THING_FIXTURE_ID="${THING_FIXTURE_ID:-thing_p2_rich_001}"
MESSAGE_SEED_FIXTURE_PATH="${MESSAGE_SEED_FIXTURE_PATH:-/Users/ethan/Repo/PushGo/pushgo/Tests/Fixtures/p2/seed-split.json}"
ENTITY_RECORD_FIXTURE_PATH="${ENTITY_RECORD_FIXTURE_PATH:-/Users/ethan/Repo/PushGo/pushgo/Tests/Fixtures/p2/seed-entity-records.json}"
SUBSCRIPTION_FIXTURE_PATH="${SUBSCRIPTION_FIXTURE_PATH:-/Users/ethan/Repo/PushGo/pushgo/Tests/Fixtures/p2/seed-subscriptions.json}"
SEED_MESSAGE_ID="${SEED_MESSAGE_ID:-msg_p2_seed_001}"
SERVER_BASE_URL="${SERVER_BASE_URL:-https://gateway.pushgo.app}"
SERVER_TOKEN="${SERVER_TOKEN:-test-token-123}"
RESPONSE_TIMEOUT_SECONDS="${RESPONSE_TIMEOUT_SECONDS:-25}"
CASE_RETRY_COUNT="${CASE_RETRY_COUNT:-2}"
NO_INTERACTIVE_SIGNING="${NO_INTERACTIVE_SIGNING:-1}"

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
need_cmd jq

cleanup() {
  set +e
  pkill -f "$APP_EXE_PATH" >/dev/null 2>&1 || true
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
    runtime_root="$(mktemp -d /tmp/pushgo-macos-smoke.${case_name}.XXXXXX)"
  fi

  local response_path="${runtime_root}/automation-response.json"
  local state_path="${runtime_root}/automation-state.json"
  local events_path="${runtime_root}/automation-events.jsonl"
  local trace_path="${runtime_root}/automation-trace.json"
  local app_log_path="${runtime_root}/app.log"

  local attempt=1
  while (( attempt <= CASE_RETRY_COUNT )); do
    echo "[macos-smoke] case=${case_name} attempt=${attempt}/${CASE_RETRY_COUNT}"
    rm -f "$response_path" "$state_path" "$events_path" "$trace_path" "$app_log_path"

    env \
      "PUSHGO_AUTOMATION_STORAGE_ROOT=${runtime_root}" \
      "PUSHGO_AUTOMATION_SKIP_PUSH_AUTHORIZATION=1" \
      "PUSHGO_AUTOMATION_ALLOW_CROSS_APP_DATA_ACCESS=0" \
      "PUSHGO_AUTOMATION_FORCE_FOREGROUND_APP=1" \
      "PUSHGO_AUTOMATION_RESPONSE_PATH=${response_path}" \
      "PUSHGO_AUTOMATION_STATE_PATH=${state_path}" \
      "PUSHGO_AUTOMATION_EVENTS_PATH=${events_path}" \
      "PUSHGO_AUTOMATION_TRACE_PATH=${trace_path}" \
      "PUSHGO_AUTOMATION_REQUEST=${request_payload}" \
      "$APP_EXE_PATH" >"$app_log_path" 2>&1 &
    local app_pid=$!

    if ! wait_for_file "$response_path" "$RESPONSE_TIMEOUT_SECONDS"; then
      kill "$app_pid" >/dev/null 2>&1 || true
      wait "$app_pid" >/dev/null 2>&1 || true
      if (( attempt == CASE_RETRY_COUNT )); then
        echo "response file missing for case=${case_name}" >&2
        cat "$app_log_path" >&2 || true
        exit 1
      fi
      sleep 1
      attempt=$((attempt + 1))
      continue
    fi
    if ! wait_for_file "$state_path" "$RESPONSE_TIMEOUT_SECONDS"; then
      kill "$app_pid" >/dev/null 2>&1 || true
      wait "$app_pid" >/dev/null 2>&1 || true
      if (( attempt == CASE_RETRY_COUNT )); then
        echo "state file missing for case=${case_name}" >&2
        cat "$app_log_path" >&2 || true
        exit 1
      fi
      sleep 1
      attempt=$((attempt + 1))
      continue
    fi

    if ! jq -e "$response_check" "$response_path" >/dev/null; then
      kill "$app_pid" >/dev/null 2>&1 || true
      wait "$app_pid" >/dev/null 2>&1 || true
      if (( attempt == CASE_RETRY_COUNT )); then
        echo "response assertion failed for case=${case_name}" >&2
        cat "$response_path" >&2
        cat "$app_log_path" >&2 || true
        exit 1
      fi
      sleep 1
      attempt=$((attempt + 1))
      continue
    fi

    if ! wait_for_jq_true "$state_path" "$state_check" "$RESPONSE_TIMEOUT_SECONDS"; then
      kill "$app_pid" >/dev/null 2>&1 || true
      wait "$app_pid" >/dev/null 2>&1 || true
      if (( attempt == CASE_RETRY_COUNT )); then
        echo "state assertion failed for case=${case_name}" >&2
        cat "$state_path" >&2
        cat "$app_log_path" >&2 || true
        exit 1
      fi
      sleep 1
      attempt=$((attempt + 1))
      continue
    fi

    if ! [[ -f "$events_path" ]] || ! [[ -s "$events_path" ]]; then
      kill "$app_pid" >/dev/null 2>&1 || true
      wait "$app_pid" >/dev/null 2>&1 || true
      if (( attempt == CASE_RETRY_COUNT )); then
        echo "events file missing/empty for case=${case_name}" >&2
        cat "$app_log_path" >&2 || true
        exit 1
      fi
      sleep 1
      attempt=$((attempt + 1))
      continue
    fi

    kill "$app_pid" >/dev/null 2>&1 || true
    wait "$app_pid" >/dev/null 2>&1 || true
    return 0
  done
}

assert_entity_opened_event() {
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

run_case \
  "nav_channels" \
  '{"id":"macos-nav-channels-001","plane":"command","name":"nav.switch_tab","args":{"tab":"channels"}}' \
  '.ok == true and .platform == "macos" and .state.runtime_error_count == 0 and .state.local_store_mode != "unavailable"' \
  '.visible_screen == "screen.channels" and .runtime_error_count == 0 and .local_store_mode != "unavailable"'

run_case \
  "hide_events_page" \
  '{"id":"macos-hide-events-001","plane":"command","name":"settings.set_page_visibility","args":{"page":"events","enabled":"false"}}' \
  '.ok == true and .platform == "macos" and .state.runtime_error_count == 0 and .state.local_store_mode != "unavailable"' \
  '.event_page_enabled == false and .runtime_error_count == 0 and .local_store_mode != "unavailable"'

run_case \
  "show_events_page" \
  '{"id":"macos-show-events-001","plane":"command","name":"settings.set_page_visibility","args":{"page":"events","enabled":"true"}}' \
  '.ok == true and .platform == "macos" and .state.runtime_error_count == 0 and .state.local_store_mode != "unavailable"' \
  '.event_page_enabled == true and .runtime_error_count == 0 and .local_store_mode != "unavailable"'

run_case \
  "set_decryption_key_base64" \
  '{"id":"macos-set-key-001","plane":"command","name":"settings.set_decryption_key","args":{"key":"MDEyMzQ1Njc4OWFiY2RlZg==","encoding":"base64"}}' \
  '.ok == true and .platform == "macos" and .state.runtime_error_count == 0 and .state.local_store_mode != "unavailable"' \
  '.notification_key_configured == true and .notification_key_encoding == "base64" and .runtime_error_count == 0 and .local_store_mode != "unavailable"'

run_case \
  "set_decryption_key_invalid" \
  '{"id":"macos-set-key-invalid-001","plane":"command","name":"settings.set_decryption_key","args":{"key":"abcd","encoding":"plain"}}' \
  '.ok == false and (.error | tostring | contains("key")) and .platform == "macos"' \
  '.runtime_error_count >= 0'

run_case \
  "fixture_import_event" \
  "{\"id\":\"macos-fixture-event-001\",\"plane\":\"command\",\"name\":\"fixture.import\",\"args\":{\"path\":\"${EVENT_FIXTURE_PATH}\"}}" \
  '.ok == true and .platform == "macos" and .state.runtime_error_count == 0 and .state.local_store_mode != "unavailable"' \
  '.event_count >= 1 and .runtime_error_count == 0 and .local_store_mode != "unavailable"'

run_case \
  "fixture_seed_messages" \
  "{\"id\":\"macos-fixture-seed-messages-001\",\"plane\":\"command\",\"name\":\"fixture.seed_messages\",\"args\":{\"path\":\"${MESSAGE_SEED_FIXTURE_PATH}\"}}" \
  '.ok == true and .platform == "macos" and .state.runtime_error_count == 0 and .state.local_store_mode != "unavailable"' \
  '.last_fixture_import_message_count == 1 and .total_message_count >= 1 and .runtime_error_count == 0 and .local_store_mode != "unavailable"'

run_case \
  "fixture_seed_entity_records" \
  "{\"id\":\"macos-fixture-seed-entities-001\",\"plane\":\"command\",\"name\":\"fixture.seed_entity_records\",\"args\":{\"path\":\"${ENTITY_RECORD_FIXTURE_PATH}\"}}" \
  '.ok == true and .platform == "macos" and .state.runtime_error_count == 0 and .state.local_store_mode != "unavailable"' \
  '.last_fixture_import_entity_record_count == 2 and .event_count >= 1 and .thing_count >= 1 and .runtime_error_count == 0 and .local_store_mode != "unavailable"'

run_case \
  "fixture_seed_subscriptions" \
  "{\"id\":\"macos-fixture-seed-subscriptions-001\",\"plane\":\"command\",\"name\":\"fixture.seed_subscriptions\",\"args\":{\"path\":\"${SUBSCRIPTION_FIXTURE_PATH}\"}}" \
  '.ok == true and .platform == "macos" and .state.runtime_error_count == 0 and .state.local_store_mode != "unavailable"' \
  '.last_fixture_import_subscription_count == 2 and .runtime_error_count == 0 and .local_store_mode != "unavailable"'

SHARED_RUNTIME_ROOT="$(mktemp -d /tmp/pushgo-macos-shared-runtime.XXXXXX)"
SHARED_MESSAGE_RUNTIME_ROOT="$(mktemp -d /tmp/pushgo-macos-message-runtime.XXXXXX)"

run_case \
  "fixture_import_event_for_entity_open" \
  "{\"id\":\"macos-fixture-event-entity-open-001\",\"plane\":\"command\",\"name\":\"fixture.import\",\"args\":{\"path\":\"${EVENT_FIXTURE_PATH}\"}}" \
  '.ok == true and .platform == "macos" and .state.runtime_error_count == 0 and .state.local_store_mode != "unavailable"' \
  '.event_count >= 1 and .runtime_error_count == 0 and .local_store_mode != "unavailable"' \
  "$SHARED_RUNTIME_ROOT"

run_case \
  "entity_open_event" \
  "{\"id\":\"macos-entity-open-event-001\",\"plane\":\"command\",\"name\":\"entity.open\",\"args\":{\"entity_type\":\"event\",\"entity_id\":\"${EVENT_FIXTURE_ID}\"}}" \
  '.ok == true and .platform == "macos" and .state.runtime_error_count == 0 and .state.local_store_mode != "unavailable"' \
  '.visible_screen == "screen.events.detail" and .opened_entity_type == "event" and .runtime_error_count == 0 and .local_store_mode != "unavailable"' \
  "$SHARED_RUNTIME_ROOT"
assert_entity_opened_event "$SHARED_RUNTIME_ROOT" "event" "$EVENT_FIXTURE_ID"

run_case \
  "fixture_import_thing_for_entity_open" \
  "{\"id\":\"macos-fixture-thing-entity-open-001\",\"plane\":\"command\",\"name\":\"fixture.import\",\"args\":{\"path\":\"${THING_FIXTURE_PATH}\"}}" \
  '.ok == true and .platform == "macos" and .state.runtime_error_count == 0 and .state.local_store_mode != "unavailable"' \
  '.thing_count >= 1 and .runtime_error_count == 0 and .local_store_mode != "unavailable"' \
  "$SHARED_RUNTIME_ROOT"

run_case \
  "entity_open_thing" \
  "{\"id\":\"macos-entity-open-thing-001\",\"plane\":\"command\",\"name\":\"entity.open\",\"args\":{\"entity_type\":\"thing\",\"entity_id\":\"${THING_FIXTURE_ID}\"}}" \
  '.ok == true and .platform == "macos" and .state.runtime_error_count == 0 and .state.local_store_mode != "unavailable"' \
  '.visible_screen == "screen.things.detail" and .opened_entity_type == "thing" and .runtime_error_count == 0 and .local_store_mode != "unavailable"' \
  "$SHARED_RUNTIME_ROOT"
assert_entity_opened_event "$SHARED_RUNTIME_ROOT" "thing" "$THING_FIXTURE_ID"

run_case \
  "fixture_seed_messages_for_notification_commands" \
  "{\"id\":\"macos-fixture-seed-message-open-001\",\"plane\":\"command\",\"name\":\"fixture.seed_messages\",\"args\":{\"path\":\"${MESSAGE_SEED_FIXTURE_PATH}\"}}" \
  '.ok == true and .platform == "macos" and .state.runtime_error_count == 0 and .state.local_store_mode != "unavailable"' \
  '.last_fixture_import_message_count == 1 and .total_message_count >= 1 and .runtime_error_count == 0 and .local_store_mode != "unavailable"' \
  "$SHARED_MESSAGE_RUNTIME_ROOT"

run_case \
  "message_open" \
  "{\"id\":\"macos-message-open-001\",\"plane\":\"command\",\"name\":\"message.open\",\"args\":{\"message_id\":\"${SEED_MESSAGE_ID}\"}}" \
  '.ok == true and .platform == "macos" and .state.runtime_error_count == 0 and .state.local_store_mode != "unavailable"' \
  ".visible_screen == \"screen.message.detail\" and .opened_message_id == \"${SEED_MESSAGE_ID}\" and .runtime_error_count == 0 and .local_store_mode != \"unavailable\"" \
  "$SHARED_MESSAGE_RUNTIME_ROOT"

run_case \
  "notification_open" \
  "{\"id\":\"macos-notification-open-001\",\"plane\":\"command\",\"name\":\"notification.open\",\"args\":{\"message_id\":\"${SEED_MESSAGE_ID}\"}}" \
  '.ok == true and .platform == "macos" and .state.runtime_error_count == 0 and .state.local_store_mode != "unavailable"' \
  ".visible_screen == \"screen.message.detail\" and .opened_message_id == \"${SEED_MESSAGE_ID}\" and .runtime_error_count == 0 and .local_store_mode != \"unavailable\"" \
  "$SHARED_MESSAGE_RUNTIME_ROOT"

run_case \
  "notification_mark_read" \
  "{\"id\":\"macos-notification-mark-read-001\",\"plane\":\"command\",\"name\":\"notification.mark_read\",\"args\":{\"message_id\":\"${SEED_MESSAGE_ID}\"}}" \
  '.ok == true and .platform == "macos" and .state.runtime_error_count == 0 and .state.local_store_mode != "unavailable"' \
  ".last_notification_action == \"mark_read\" and .last_notification_target == \"${SEED_MESSAGE_ID}\" and .unread_message_count == 0 and .runtime_error_count == 0 and .local_store_mode != \"unavailable\"" \
  "$SHARED_MESSAGE_RUNTIME_ROOT"

run_case \
  "notification_delete" \
  "{\"id\":\"macos-notification-delete-001\",\"plane\":\"command\",\"name\":\"notification.delete\",\"args\":{\"message_id\":\"${SEED_MESSAGE_ID}\"}}" \
  '.ok == true and .platform == "macos" and .state.runtime_error_count == 0 and .state.local_store_mode != "unavailable"' \
  ".last_notification_action == \"delete\" and .last_notification_target == \"${SEED_MESSAGE_ID}\" and .total_message_count == 0 and .runtime_error_count == 0 and .local_store_mode != \"unavailable\"" \
  "$SHARED_MESSAGE_RUNTIME_ROOT"

run_case \
  "gateway_set_server" \
  "{\"id\":\"macos-gateway-set-server-001\",\"plane\":\"command\",\"name\":\"gateway.set_server\",\"args\":{\"base_url\":\"${SERVER_BASE_URL}\",\"token\":\"${SERVER_TOKEN}\"}}" \
  ".ok == true and .platform == \"macos\" and .state.gateway_base_url == \"${SERVER_BASE_URL}\" and .state.gateway_token_present == true and .state.runtime_error_count == 0 and .state.local_store_mode != \"unavailable\"" \
  ".gateway_base_url == \"${SERVER_BASE_URL}\" and .gateway_token_present == true and .runtime_error_count == 0 and .local_store_mode != \"unavailable\""

echo "[macos-smoke] all cases passed"
