#!/usr/bin/env bash
set -euo pipefail

PROJECT_PATH="${PROJECT_PATH:-/Users/ethan/Repo/PushGo/pushgo/pushgo.xcodeproj}"
SCHEME="${SCHEME:-PushGo-watchOS}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/pushgo-watchos-automation}"
WATCH_BUNDLE_ID="${WATCH_BUNDLE_ID:-io.ethan.pushgo.watchkitapp}"
WATCH_DEVICE_ID="${WATCH_DEVICE_ID:-}"
WATCH_DEVICE_NAME="${WATCH_DEVICE_NAME:-Apple Watch Series 11 (42mm)}"
IPHONE_DEVICE_ID="${IPHONE_DEVICE_ID:-}"
IPHONE_DEVICE_NAME="${IPHONE_DEVICE_NAME:-iPhone Air}"
EVENT_FIXTURE_PATH="${EVENT_FIXTURE_PATH:-/Users/ethan/Repo/PushGo/pushgo/Tests/Fixtures/p2/event-lifecycle.json}"
THING_FIXTURE_PATH="${THING_FIXTURE_PATH:-/Users/ethan/Repo/PushGo/pushgo/Tests/Fixtures/p2/rich-thing-detail.json}"
EVENT_FIXTURE_ID="${EVENT_FIXTURE_ID:-evt_p2_active_001}"
THING_FIXTURE_ID="${THING_FIXTURE_ID:-thing_p2_rich_001}"
COLD_BOOT="${COLD_BOOT:-1}"
AUTO_SHUTDOWN="${AUTO_SHUTDOWN:-1}"
BOOT_IPHONE="${BOOT_IPHONE:-0}"
RESPONSE_TIMEOUT_SECONDS="${RESPONSE_TIMEOUT_SECONDS:-25}"
CASE_RETRY_COUNT="${CASE_RETRY_COUNT:-2}"
NO_INTERACTIVE_SIGNING="${NO_INTERACTIVE_SIGNING:-1}"
RUNTIME_QUALITY_CASE="${RUNTIME_QUALITY_CASE:-0}"
RUNTIME_QUALITY_ONLY="${RUNTIME_QUALITY_ONLY:-0}"
RUNTIME_QUALITY_SCALE="${RUNTIME_QUALITY_SCALE:-10000}"
RUNTIME_QUALITY_FIXTURE_PATH="${RUNTIME_QUALITY_FIXTURE_PATH:-}"
WATCH_RUNTIME_DETAIL_READY_TIMEOUT_SECONDS="${WATCH_RUNTIME_DETAIL_READY_TIMEOUT_SECONDS:-}"
WATCH_RUNTIME_DETAIL_RETURN_TIMEOUT_SECONDS="${WATCH_RUNTIME_DETAIL_RETURN_TIMEOUT_SECONDS:-}"

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

resolve_device_id() {
  local platform_regex="$1"
  local preferred_id="$2"
  local preferred_name="$3"
  local devices_json="$4"

  if [[ -n "$preferred_id" ]] && jq -e --arg id "$preferred_id" '
      .devices[]?[]? | select(.isAvailable == true and .udid == $id)
    ' <<<"$devices_json" >/dev/null; then
    echo "$preferred_id"
    return 0
  fi

  if [[ -n "$preferred_name" ]]; then
    local by_name
    by_name="$(jq -r --arg name "$preferred_name" '
      .devices[]?[]?
      | select(.isAvailable == true and .name == $name)
      | .udid
    ' <<<"$devices_json" | head -n 1)"
    if [[ -n "$by_name" ]]; then
      echo "$by_name"
      return 0
    fi
  fi

  local fallback
  fallback="$(jq -r --arg regex "$platform_regex" '
    .devices[]?[]?
    | select(.isAvailable == true and (.name | test($regex)))
    | .udid
  ' <<<"$devices_json" | head -n 1)"
  if [[ -n "$fallback" ]]; then
    echo "$fallback"
    return 0
  fi
  return 1
}

SIMCTL_DEVICES_JSON="$(xcrun simctl list devices available -j)"
WATCH_DEVICE_ID="$(resolve_device_id "^Apple Watch" "$WATCH_DEVICE_ID" "$WATCH_DEVICE_NAME" "$SIMCTL_DEVICES_JSON")" || {
  echo "unable to resolve available watchOS simulator device id" >&2
  exit 1
}
if [[ "$BOOT_IPHONE" == "1" ]]; then
  IPHONE_DEVICE_ID="$(resolve_device_id "^iPhone" "$IPHONE_DEVICE_ID" "$IPHONE_DEVICE_NAME" "$SIMCTL_DEVICES_JSON")" || {
    echo "unable to resolve available iOS simulator device id" >&2
    exit 1
  }
fi

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

write_runtime_quality_fixture() {
  local fixture_path="$1"
  local message_count="$2"
  jq -n --argjson count "$message_count" '
    def markdown_block($label; $section):
      "## \($label) section \($section)\n\n- watch runtime detail rendering\n- unicode 中文 English 日本語 한국어 عربى\n- repeated links https://example.com/pushgo/watch/\($label)/\($section)\n\n| field | value |\n| --- | --- |\n| label | \($label) |\n| section | \($section) |\n| mode | render-profile |\n\n> Dense watch detail profile for markdown wrapping and list rendering.";
    def markdown_body($label; $repeat_count; $long_line):
      ([range(0; $repeat_count) | markdown_block($label; .)] | join("\n\n"))
      + (if $long_line then
          "\n\n" + ([range(0; 240) | "LongLine-\($label)-0123456789中文日本語한국어عربى"] | join(""))
         else "" end);
    def title($i):
      if ($i % 8) == 0 then "Runtime quality alert \($i)"
      elif ($i % 8) == 1 then "发布流程检查 \($i)"
      elif ($i % 8) == 2 then "イベント更新 \($i)"
      elif ($i % 8) == 3 then "تنبيه تشغيل \($i)"
      else "Watch message \($i)"
      end;
    def body($i):
      if $i == 0 then
        markdown_body("baseline"; 4; false)
      elif $i == 1 then
        markdown_body("markdown-10k"; 24; false)
      elif $i == 2 then
        markdown_body("markdown-26k"; 63; false)
      elif $i == 3 then
        markdown_body("media-rich"; 56; false)
      elif $i == 4 then
        markdown_body("longline-unicode"; 20; true)
      elif ($i % 17) == 0 then
        ([range(0; 28) | "Long watch body \($i)"] | join(" "))
      elif ($i % 13) == 0 then
        "Mixed Unicode body \($i): 中文 English 日本語 한국어 عربى"
      else
        "Runtime watch body \($i) with https://example.com and list/detail content."
      end;
    def scenario($i):
      if $i == 0 then "baseline_detail"
      elif $i == 1 then "markdown_10k"
      elif $i == 2 then "markdown_26k"
      elif $i == 3 then "media_rich"
      elif $i == 4 then "longline_unicode"
      else ["normal", "unicode_mixed", "rtl_text", "long_markdown", "same_timestamp", "out_of_order", "duplicate_identity", "url"][$i % 8]
      end;
    {
      messages: [
        range(0; $count) as $i
        | {
            message_id: "runtime-watch-msg-\($i)",
            title: title($i),
            body: body($i),
            channel_id: "runtime-watch-channel-\($i % 24)",
            url: "https://example.com/pushgo/watch/\($i)",
            is_read: (($i % 3) == 0),
            received_at: "2026-01-01T00:00:00Z",
            status: "normal",
            raw_payload: {
              watch_light_kind: "message",
              message_id: "runtime-watch-msg-\($i)",
              title: title($i),
              body: body($i),
              channel_id: "runtime-watch-channel-\($i % 24)",
              url: "https://example.com/pushgo/watch/\($i)",
              sent_at: "2026-01-01T00:00:00Z",
              severity: (["info", "success", "warning", "critical"][$i % 4]),
              scenario: scenario($i),
              tags: "runtimequality,channel-\($i % 24)",
              op_id: "runtime-watch-op-\($i % 7500)"
            }
          }
      ],
      entity_records: [],
      channel_subscriptions: []
    }
  ' >"$fixture_path"
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

assert_fixture_imported_message_count() {
  local runtime_root="$1"
  local expected_count="$2"
  local events_path="${runtime_root}/automation-events.jsonl"
  jq -Rse --arg expected "$expected_count" \
    '
      split("\n")
      | map(select(length > 0) | fromjson?)
      | map(select(.type == "fixture.imported" and .details.message_count == $expected))
      | length >= 1
    ' \
    "$events_path" >/dev/null
}

assert_message_detail_ready_event() {
  local runtime_root="$1"
  local message_id="$2"
  local events_path="${runtime_root}/automation-events.jsonl"
  jq -Rse \
    '
      split("\n")
      | map(select(length > 0) | fromjson?)
      | map(select(.type == "message.detail_ready" and .details.message_id == "'"${message_id}"'"))
      | length >= 1
    ' \
    "$events_path" >/dev/null
}

runtime_performance_summary() {
  local runtime_root="$1"
  local state_path="${runtime_root}/automation-state.json"
  jq -r '"residentMemoryBytes=\(.resident_memory_bytes // -1) mainThreadMaxStallMs=\(.main_thread_max_stall_ms // -1)"' "$state_path"
}

assert_runtime_detail_variants_event() {
  local runtime_root="$1"
  local events_path="${runtime_root}/automation-events.jsonl"
  jq -Rse \
    '
      split("\n")
      | map(select(length > 0) | fromjson?)
      | map(select(.type == "runtime.detail_variants"))
      | any(
          (.details.baseline_ms | tonumber) >= 0
          and (.details.markdown_10k_ms | tonumber) >= 0
          and (.details.markdown_26k_ms | tonumber) >= 0
          and (.details.media_rich_ms | tonumber) >= 0
          and (.details.longline_unicode_ms | tonumber) >= 0
          and (.details.baseline_repeat_ms | tonumber) >= 0
        )
    ' \
    "$events_path" >/dev/null
}

runtime_detail_variants_summary() {
  local runtime_root="$1"
  local events_path="${runtime_root}/automation-events.jsonl"
  jq -Rse -r \
    '
      split("\n")
      | map(select(length > 0) | fromjson?)
      | map(select(.type == "runtime.detail_variants"))
      | last
      | .details
      | "baseline=\(.baseline_ms)ms md10k=\(.markdown_10k_ms)ms md26k=\(.markdown_26k_ms)ms media=\(.media_rich_ms)ms longline=\(.longline_unicode_ms)ms repeat=\(.baseline_repeat_ms)ms"
    ' \
    "$events_path"
}

assert_runtime_list_reloads_event() {
  local runtime_root="$1"
  local events_path="${runtime_root}/automation-events.jsonl"
  jq -Rse \
    '
      split("\n")
      | map(select(length > 0) | fromjson?)
      | map(select(.type == "runtime.list_reloads"))
      | any(
          (.details.iteration_count | tonumber) == 10
          and (.details.first_reload_ms | tonumber) >= 0
          and (.details.last_reload_ms | tonumber) >= 0
          and (.details.max_reload_ms | tonumber) >= 0
          and (.details.message_count | tonumber) > 0
        )
    ' \
    "$events_path" >/dev/null
}

runtime_list_reloads_summary() {
  local runtime_root="$1"
  local events_path="${runtime_root}/automation-events.jsonl"
  jq -Rse -r \
    '
      split("\n")
      | map(select(length > 0) | fromjson?)
      | map(select(.type == "runtime.list_reloads"))
      | last
      | .details
      | "reloads=\(.iteration_count) first=\(.first_reload_ms)ms last=\(.last_reload_ms)ms max=\(.max_reload_ms)ms messages=\(.message_count)"
    ' \
    "$events_path"
}

assert_runtime_detail_cycles_event() {
  local runtime_root="$1"
  local events_path="${runtime_root}/automation-events.jsonl"
  jq -Rse \
    '
      split("\n")
      | map(select(length > 0) | fromjson?)
      | map(select(.type == "runtime.detail_cycles"))
      | any(
          (.details.cycles_per_scenario | tonumber) == 20
          and (.details.normal_avg_cycle_ms | tonumber) >= 0
          and (.details.markdown_26k_avg_cycle_ms | tonumber) >= 0
          and (.details.media_avg_cycle_ms | tonumber) >= 0
        )
    ' \
    "$events_path" >/dev/null
}

runtime_detail_cycles_summary() {
  local runtime_root="$1"
  local events_path="${runtime_root}/automation-events.jsonl"
  jq -Rse -r \
    '
      split("\n")
      | map(select(length > 0) | fromjson?)
      | map(select(.type == "runtime.detail_cycles"))
      | last
      | .details
      | "normal=\(.normal_avg_cycle_ms)ms md26k=\(.markdown_26k_avg_cycle_ms)ms media=\(.media_avg_cycle_ms)ms mediaPeakDelta=\(.media_resident_memory_peak_delta_bytes)"
    ' \
    "$events_path"
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
      "SIMCTL_CHILD_PUSHGO_WATCH_RUNTIME_DETAIL_READY_TIMEOUT_SECONDS=${WATCH_RUNTIME_DETAIL_READY_TIMEOUT_SECONDS}" \
      "SIMCTL_CHILD_PUSHGO_WATCH_RUNTIME_DETAIL_RETURN_TIMEOUT_SECONDS=${WATCH_RUNTIME_DETAIL_RETURN_TIMEOUT_SECONDS}" \
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

if [[ "$RUNTIME_QUALITY_ONLY" != "1" ]]; then
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
fi

if [[ "$RUNTIME_QUALITY_CASE" == "1" ]]; then
  if [[ -z "$RUNTIME_QUALITY_FIXTURE_PATH" ]]; then
    RUNTIME_QUALITY_FIXTURE_PATH="$(mktemp -d /tmp/pushgo-watchos-runtime-quality-fixture.XXXXXX)/runtime-quality-watchos.json"
    fixture_started_at="$(date +%s)"
    write_runtime_quality_fixture "$RUNTIME_QUALITY_FIXTURE_PATH" "$RUNTIME_QUALITY_SCALE"
    fixture_finished_at="$(date +%s)"
    fixture_duration=$((fixture_finished_at - fixture_started_at))
  else
    fixture_duration="prebuilt"
  fi

  RUNTIME_ROOT="$(mktemp -d /tmp/pushgo-watchos-runtime-quality.XXXXXX)"
  runtime_started_at="$(date +%s)"
  run_case \
    "runtime_quality_large_fixture" \
    "{\"id\":\"watch-runtime-quality-large-001\",\"plane\":\"command\",\"name\":\"fixture.seed_messages\",\"args\":{\"path\":\"${RUNTIME_QUALITY_FIXTURE_PATH}\"}}" \
    ".ok == true and .platform == \"watchos\" and .state.total_message_count == ${RUNTIME_QUALITY_SCALE} and .state.runtime_error_count == 0 and .state.local_store_mode != \"unavailable\"" \
    ".total_message_count == ${RUNTIME_QUALITY_SCALE} and .runtime_error_count == 0 and .local_store_mode != \"unavailable\"" \
    "$RUNTIME_ROOT"
  assert_fixture_imported_message_count "$RUNTIME_ROOT" "$RUNTIME_QUALITY_SCALE"
  runtime_finished_at="$(date +%s)"
  runtime_duration=$((runtime_finished_at - runtime_started_at))
  runtime_metrics="$(runtime_performance_summary "$RUNTIME_ROOT")"

  detail_variants_started_at="$(date +%s)"
  run_case \
    "runtime_quality_detail_variants" \
    "{\"id\":\"watch-runtime-quality-detail-variants-001\",\"plane\":\"command\",\"name\":\"runtime.measure_detail_variants\"}" \
    ".ok == true and .platform == \"watchos\" and .state.runtime_error_count == 0 and .state.local_store_mode != \"unavailable\"" \
    ".runtime_error_count == 0 and .local_store_mode != \"unavailable\"" \
    "$RUNTIME_ROOT"
  assert_runtime_detail_variants_event "$RUNTIME_ROOT"
  detail_variant_metrics="$(runtime_detail_variants_summary "$RUNTIME_ROOT")"
  detail_variants_finished_at="$(date +%s)"
  detail_variants_duration=$((detail_variants_finished_at - detail_variants_started_at))

  list_reloads_started_at="$(date +%s)"
  run_case \
    "runtime_quality_list_reloads" \
    "{\"id\":\"watch-runtime-quality-list-reloads-001\",\"plane\":\"command\",\"name\":\"runtime.measure_list_reloads\"}" \
    ".ok == true and .platform == \"watchos\" and .state.runtime_error_count == 0 and .state.local_store_mode != \"unavailable\"" \
    ".runtime_error_count == 0 and .local_store_mode != \"unavailable\"" \
    "$RUNTIME_ROOT"
  assert_runtime_list_reloads_event "$RUNTIME_ROOT"
  list_reload_metrics="$(runtime_list_reloads_summary "$RUNTIME_ROOT")"
  list_reloads_finished_at="$(date +%s)"
  list_reloads_duration=$((list_reloads_finished_at - list_reloads_started_at))

  detail_cycles_started_at="$(date +%s)"
  run_case \
    "runtime_quality_detail_cycles" \
    "{\"id\":\"watch-runtime-quality-detail-cycles-001\",\"plane\":\"command\",\"name\":\"runtime.measure_detail_cycles\"}" \
    ".ok == true and .platform == \"watchos\" and .state.runtime_error_count == 0 and .state.local_store_mode != \"unavailable\"" \
    ".runtime_error_count == 0 and .local_store_mode != \"unavailable\"" \
    "$RUNTIME_ROOT"
  assert_runtime_detail_cycles_event "$RUNTIME_ROOT"
  detail_cycles_metrics="$(runtime_detail_cycles_summary "$RUNTIME_ROOT")"
  detail_cycles_finished_at="$(date +%s)"
  detail_cycles_duration=$((detail_cycles_finished_at - detail_cycles_started_at))

  detail_started_at="$(date +%s)"
  run_case \
    "runtime_quality_message_detail" \
    "{\"id\":\"watch-runtime-quality-detail-001\",\"plane\":\"command\",\"name\":\"message.open\",\"args\":{\"message_id\":\"runtime-watch-msg-0\"}}" \
    ".ok == true and .platform == \"watchos\" and .state.runtime_error_count == 0 and .state.local_store_mode != \"unavailable\"" \
    ".runtime_error_count == 0 and .local_store_mode != \"unavailable\"" \
    "$RUNTIME_ROOT"
  assert_message_detail_ready_event "$RUNTIME_ROOT" "runtime-watch-msg-0"
  detail_finished_at="$(date +%s)"
  detail_duration=$((detail_finished_at - detail_started_at))
  detail_metrics="$(runtime_performance_summary "$RUNTIME_ROOT")"

  event_detail_started_at="$(date +%s)"
  run_case \
    "runtime_quality_event_import" \
    "{\"id\":\"watch-runtime-quality-event-import-001\",\"plane\":\"command\",\"name\":\"fixture.import\",\"args\":{\"path\":\"${EVENT_FIXTURE_PATH}\"}}" \
    ".ok == true and .platform == \"watchos\" and .state.runtime_error_count == 0" \
    ".event_count >= 1 and .runtime_error_count == 0" \
    "$RUNTIME_ROOT"
  run_case \
    "runtime_quality_event_detail" \
    "{\"id\":\"watch-runtime-quality-event-detail-001\",\"plane\":\"command\",\"name\":\"entity.open\",\"args\":{\"entity_type\":\"event\",\"entity_id\":\"${EVENT_FIXTURE_ID}\"}}" \
    ".ok == true and .platform == \"watchos\" and .state.runtime_error_count == 0 and .state.opened_entity_type == \"event\"" \
    ".runtime_error_count == 0" \
    "$RUNTIME_ROOT"
  assert_entity_opened_event_in_events_file "$RUNTIME_ROOT" "event" "$EVENT_FIXTURE_ID"
  event_detail_finished_at="$(date +%s)"
  event_detail_duration=$((event_detail_finished_at - event_detail_started_at))
  event_detail_metrics="$(runtime_performance_summary "$RUNTIME_ROOT")"

  thing_detail_started_at="$(date +%s)"
  run_case \
    "runtime_quality_thing_import" \
    "{\"id\":\"watch-runtime-quality-thing-import-001\",\"plane\":\"command\",\"name\":\"fixture.import\",\"args\":{\"path\":\"${THING_FIXTURE_PATH}\"}}" \
    ".ok == true and .platform == \"watchos\" and .state.runtime_error_count == 0" \
    ".thing_count >= 1 and .runtime_error_count == 0" \
    "$RUNTIME_ROOT"
  run_case \
    "runtime_quality_thing_detail" \
    "{\"id\":\"watch-runtime-quality-thing-detail-001\",\"plane\":\"command\",\"name\":\"entity.open\",\"args\":{\"entity_type\":\"thing\",\"entity_id\":\"${THING_FIXTURE_ID}\"}}" \
    ".ok == true and .platform == \"watchos\" and .state.runtime_error_count == 0 and .state.opened_entity_type == \"thing\"" \
    ".runtime_error_count == 0" \
    "$RUNTIME_ROOT"
  assert_entity_opened_event_in_events_file "$RUNTIME_ROOT" "thing" "$THING_FIXTURE_ID"
  thing_detail_finished_at="$(date +%s)"
  thing_detail_duration=$((thing_detail_finished_at - thing_detail_started_at))
  thing_detail_metrics="$(runtime_performance_summary "$RUNTIME_ROOT")"

  echo "[runtime-quality-watchos] scale=${RUNTIME_QUALITY_SCALE} fixtureGeneration=${fixture_duration}s launchImportListReady=${runtime_duration}s launchMetrics=${runtime_metrics} detailVariantsReady=${detail_variants_duration}s detailVariantMetrics=${detail_variant_metrics} listReloadsReady=${list_reloads_duration}s listReloadMetrics=${list_reload_metrics} detailCyclesReady=${detail_cycles_duration}s detailCyclesMetrics=${detail_cycles_metrics} messageDetailReady=${detail_duration}s messageDetailMetrics=${detail_metrics} eventDetailReady=${event_detail_duration}s eventDetailMetrics=${event_detail_metrics} thingDetailReady=${thing_detail_duration}s thingDetailMetrics=${thing_detail_metrics}"
fi

echo "[watchos-smoke] all cases passed"
