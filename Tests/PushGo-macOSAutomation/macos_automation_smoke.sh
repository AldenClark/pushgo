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
RUNTIME_QUALITY_CASE="${RUNTIME_QUALITY_CASE:-0}"
RUNTIME_QUALITY_ONLY="${RUNTIME_QUALITY_ONLY:-0}"
RUNTIME_QUALITY_SCALE="${RUNTIME_QUALITY_SCALE:-10000}"
RUNTIME_QUALITY_FIXTURE_PATH="${RUNTIME_QUALITY_FIXTURE_PATH:-}"
RUNTIME_QUALITY_STAGE_STOP="${RUNTIME_QUALITY_STAGE_STOP:-}"

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

write_runtime_quality_fixture() {
  local fixture_path="$1"
  local message_count="$2"
  jq -n --argjson count "$message_count" '
    def markdown_block($label; $section):
      "## \($label) section \($section)\n\n- runtime quality detail rendering\n- unicode 中文 English 日本語 한국어 عربى\n- repeated links https://example.com/pushgo/\($label)/\($section)\n\n| field | value |\n| --- | --- |\n| label | \($label) |\n| section | \($section) |\n| mode | render-profile |\n\n```json\n{\"label\":\"\($label)\",\"section\":\($section),\"mode\":\"render-profile\"}\n```\n\n> This profile is intentionally dense to exercise markdown layout, line wrapping, tables, and code blocks.";
    def markdown_body($label; $repeat_count; $image_count; $long_line):
      ([range(0; $repeat_count) | markdown_block($label; .)] | join("\n\n"))
      + (if $image_count > 0 then
          "\n\n" + ([range(0; $image_count) | "![render-\(.)](https://runtime-quality.example.com/assets/\($label)-\(.).png)"] | join("\n"))
         else "" end)
      + (if $long_line then
          "\n\n" + ([range(0; 320) | "LongLine-\($label)-0123456789中文日本語한국어عربى"] | join(""))
         else "" end);
    def title($i):
      if ($i % 8) == 0 then "Runtime quality alert \($i)"
      elif ($i % 8) == 1 then "发布流程检查 \($i)"
      elif ($i % 8) == 2 then "イベント更新 \($i)"
      elif ($i % 8) == 3 then "تنبيه تشغيل \($i)"
      else "Message \($i)"
      end;
    def body($i):
      if $i == 0 then
        markdown_body("baseline"; 6; 0; false)
      elif $i == 1 then
        markdown_body("markdown-10k"; 28; 0; false)
      elif $i == 2 then
        markdown_body("markdown-26k"; 62; 0; false)
      elif $i == 3 then
        markdown_body("media-rich"; 60; 18; false)
      elif $i == 4 then
        markdown_body("longline-unicode"; 20; 0; true)
      elif ($i % 17) == 0 then
        ([range(0; 40) | "Long markdown body \($i)"] | join(" "))
      elif ($i % 13) == 0 then
        "Mixed Unicode body \($i): 中文 English 日本語 한국어 عربى"
      else
        "Runtime quality body \($i) with https://example.com and list/detail content."
      end;
    def entity_type($i):
      if ($i % 10) == 1 then "event"
      elif (($i % 10) == 2 or ($i % 10) == 3) then "thing"
      else null
      end;
    def tags($i):
      ["runtimequality", "channel-\($i % 32)"]
      + (if ($i % 10) == 4 then ["task"] else [] end)
      + (if ($i % 7) == 0 then ["url"] else [] end);
    def scenario($i):
      if $i == 0 then "baseline_detail"
      elif $i == 1 then "markdown_10k"
      elif $i == 2 then "markdown_26k"
      elif $i == 3 then "media_rich"
      elif $i == 4 then "longline_unicode"
      else ["normal", "unicode_mixed", "rtl_text", "long_markdown", "task_like", "same_timestamp", "out_of_order", "duplicate_identity"][$i % 8]
      end;
    {
      messages: [
        range(0; $count) as $i
        | (entity_type($i)) as $entityType
        | {
            message_id: "runtime-ui-msg-\($i)",
            title: title($i),
            body: body($i),
            channel_id: "runtime-channel-\($i % 32)",
            url: "https://example.com/pushgo/runtime/\($i)",
            is_read: (($i % 3) == 0),
            received_at: "2026-01-01T00:00:00Z",
            status: "normal",
            raw_payload: ({
              runtime_quality: true,
              scenario: scenario($i),
              tags: (tags($i) | tojson),
              markdown: body($i),
              op_id: "runtime-op-\($i % 7500)"
            }
            + (if $entityType == null then {}
               elif $entityType == "event" then {entity_type: $entityType, entity_id: "event-runtime-\($i % 2000)", event_id: "event-runtime-\($i % 2000)"}
               else {entity_type: $entityType, entity_id: "thing-runtime-\($i % 2000)", thing_id: "thing-runtime-\($i % 2000)"}
               end)
            + (if ($i % 10) == 4 then {task_id: "task-runtime-\($i % 1000)", task_state: (["todo", "doing", "blocked", "done"][$i % 4])} else {} end))
          }
      ],
      entity_records: [],
      channel_subscriptions: []
    }
  ' >"$fixture_path"
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
  local preserve_runtime_events=0
  if [[ -n "$runtime_root_override" ]] && [[ "$RUNTIME_QUALITY_CASE" == "1" ]]; then
    preserve_runtime_events=1
  fi

  local attempt=1
  while (( attempt <= CASE_RETRY_COUNT )); do
    echo "[macos-smoke] case=${case_name} attempt=${attempt}/${CASE_RETRY_COUNT}"
    if (( preserve_runtime_events == 1 )); then
      rm -f "$response_path" "$state_path" "$app_log_path"
    else
      rm -f "$response_path" "$state_path" "$events_path" "$trace_path" "$app_log_path"
    fi

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

assert_runtime_message_queries_event() {
  local runtime_root="$1"
  local events_path="${runtime_root}/automation-events.jsonl"
  jq -Rse \
    '
      split("\n")
      | map(select(length > 0) | fromjson?)
      | map(select(.type == "runtime.message_queries"))
      | any(
          (.details.first_page_count | tonumber) == 50
          and (.details.second_page_count | tonumber) == 50
          and (.details.unread_page_count | tonumber) > 0
          and (.details.tag_page_count | tonumber) > 0
          and (.details.search_count | tonumber) > 0
          and (.details.search_page_count | tonumber) > 0
          and (.details.first_page_ms | tonumber) < 10000
          and (.details.second_page_ms | tonumber) < 10000
          and (.details.unread_page_ms | tonumber) < 10000
          and (.details.tag_page_ms | tonumber) < 10000
          and (.details.search_count_ms | tonumber) < 10000
          and (.details.search_page_ms | tonumber) < 10000
        )
    ' \
    "$events_path" >/dev/null
}

runtime_message_queries_summary() {
  local runtime_root="$1"
  local events_path="${runtime_root}/automation-events.jsonl"
  jq -Rse -r \
    '
      split("\n")
      | map(select(length > 0) | fromjson?)
      | map(select(.type == "runtime.message_queries"))
      | last
      | .details
      | "firstPage=\(.first_page_count)/\(.first_page_ms)ms secondPage=\(.second_page_count)/\(.second_page_ms)ms unreadPage=\(.unread_page_count)/\(.unread_page_ms)ms tagPage=\(.tag_page_count)/\(.tag_page_ms)ms searchCount=\(.search_count)/\(.search_count_ms)ms searchPage=\(.search_page_count)/\(.search_page_ms)ms"
    ' \
    "$events_path"
}

assert_runtime_sort_modes_event() {
  local runtime_root="$1"
  local events_path="${runtime_root}/automation-events.jsonl"
  jq -Rse \
    '
      split("\n")
      | map(select(length > 0) | fromjson?)
      | map(select(.type == "runtime.sort_modes"))
      | any(
          (.details.query_time_desc_page_count | tonumber) > 0
          and (.details.query_unread_first_page_count | tonumber) > 0
          and (.details.query_time_desc_page_ms | tonumber) >= 0
          and (.details.query_unread_first_page_ms | tonumber) >= 0
          and (.details.viewmodel_set_sort_time_desc_ms | tonumber) >= 0
          and (.details.viewmodel_set_sort_unread_first_ms | tonumber) >= 0
          and (.details.ui_ready_time_desc_ms | tonumber) >= 0
          and (.details.ui_ready_unread_first_ms | tonumber) >= 0
        )
    ' \
    "$events_path" >/dev/null
}

runtime_sort_modes_summary() {
  local runtime_root="$1"
  local events_path="${runtime_root}/automation-events.jsonl"
  jq -Rse -r \
    '
      split("\n")
      | map(select(length > 0) | fromjson?)
      | map(select(.type == "runtime.sort_modes"))
      | last
      | .details
      | "query=time_desc:\(.query_time_desc_page_ms)ms unread_first:\(.query_unread_first_page_ms)ms vm=time_desc:\(.viewmodel_set_sort_time_desc_ms)ms unread_first:\(.viewmodel_set_sort_unread_first_ms)ms ui=time_desc:\(.ui_ready_time_desc_ms)ms unread_first:\(.ui_ready_unread_first_ms)ms"
    ' \
    "$events_path"
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
      | "baseline=\(.baseline_ms)ms/\(.baseline_source) split=\(.baseline_store_lookup_ms)+\(.baseline_markdown_prepare_ms)+\(.baseline_ui_open_wait_ms)ms attach(resolve=\(.baseline_attachment_resolve_delta),cacheHit=\(.baseline_attachment_cache_hit_delta),cacheMiss=\(.baseline_attachment_cache_miss_delta),metaSync=\(.baseline_attachment_metadata_sync_hit_delta),metaAsync=\(.baseline_attachment_metadata_async_hit_delta),animated=\(.baseline_attachment_animated_delta)) md10k=\(.markdown_10k_ms)ms md26k=\(.markdown_26k_ms)ms media=\(.media_rich_ms)ms longline=\(.longline_unicode_ms)ms repeat=\(.baseline_repeat_ms)ms/\(.baseline_repeat_source)"
    ' \
    "$events_path"
}

assert_runtime_window_resize_event() {
  local runtime_root="$1"
  local events_path="${runtime_root}/automation-events.jsonl"
  jq -Rse \
    '
      split("\n")
      | map(select(length > 0) | fromjson?)
      | map(select(.type == "runtime.window_resize"))
      | any(
          (.details.step_count | tonumber) == 3
          and (.details.step_0_ms | tonumber) >= 0
          and (.details.step_1_ms | tonumber) >= 0
          and (.details.step_2_ms | tonumber) >= 0
        )
    ' \
    "$events_path" >/dev/null
}

runtime_window_resize_summary() {
  local runtime_root="$1"
  local events_path="${runtime_root}/automation-events.jsonl"
  jq -Rse -r \
    '
      split("\n")
      | map(select(length > 0) | fromjson?)
      | map(select(.type == "runtime.window_resize"))
      | last
      | .details
      | "w0=\(.step_0_width)/\(.step_0_ms)ms w1=\(.step_1_width)/\(.step_1_ms)ms w2=\(.step_2_width)/\(.step_2_ms)ms"
    ' \
    "$events_path"
}

assert_runtime_media_cycles_event() {
  local runtime_root="$1"
  local events_path="${runtime_root}/automation-events.jsonl"
  jq -Rse \
    '
      split("\n")
      | map(select(length > 0) | fromjson?)
      | map(select(.type == "runtime.media_cycles"))
      | any(
          (.details.iteration_count | tonumber) >= 5
          and (.details.first_open_ms | tonumber) >= 0
          and (.details.repeat_avg_ms | tonumber) >= 0
          and (.details.repeat_max_ms | tonumber) >= 0
          and (.details.image_url_count | tonumber) >= 0
        )
    ' \
    "$events_path" >/dev/null
}

runtime_media_cycles_summary() {
  local runtime_root="$1"
  local events_path="${runtime_root}/automation-events.jsonl"
  jq -Rse -r \
    '
      split("\n")
      | map(select(length > 0) | fromjson?)
      | map(select(.type == "runtime.media_cycles"))
      | last
      | .details
      | "media first=\(.first_open_ms)ms repeatAvg=\(.repeat_avg_ms)ms repeatMax=\(.repeat_max_ms)ms listReturnAvg=\(.list_return_avg_ms)ms readySources=\(.ready_sources) rssDelta=\(.resident_memory_delta_bytes) peakDelta=\(.resident_memory_peak_delta_bytes)"
    ' \
    "$events_path"
}

assert_runtime_detail_release_cycles_event() {
  local runtime_root="$1"
  local events_path="${runtime_root}/automation-events.jsonl"
  jq -Rse \
    '
      split("\n")
      | map(select(length > 0) | fromjson?)
      | map(select(.type == "runtime.detail_release_cycles"))
      | any(
          (.details.cycles_per_scenario | tonumber) == 20
          and (.details.normal_avg_cycle_ms | tonumber) >= 0
          and (.details.markdown_26k_avg_cycle_ms | tonumber) >= 0
          and (.details.media_avg_cycle_ms | tonumber) >= 0
        )
    ' \
    "$events_path" >/dev/null
}

runtime_detail_release_cycles_summary() {
  local runtime_root="$1"
  local events_path="${runtime_root}/automation-events.jsonl"
  jq -Rse -r \
    '
      split("\n")
      | map(select(length > 0) | fromjson?)
      | map(select(.type == "runtime.detail_release_cycles"))
      | last
      | .details
      | "normal=\(.normal_avg_cycle_ms)ms(open=\(.normal_open_detail_avg_ms),return=\(.normal_return_list_avg_ms),miss=\(.normal_detail_ready_miss_count)/\(.normal_list_return_miss_count)) md26k=\(.markdown_26k_avg_cycle_ms)ms(open=\(.markdown_26k_open_detail_avg_ms),return=\(.markdown_26k_return_list_avg_ms),miss=\(.markdown_26k_detail_ready_miss_count)/\(.markdown_26k_list_return_miss_count)) media=\(.media_avg_cycle_ms)ms(open=\(.media_open_detail_avg_ms),return=\(.media_return_list_avg_ms),miss=\(.media_detail_ready_miss_count)/\(.media_list_return_miss_count)) rssPeakDelta(media)=\(.media_resident_memory_peak_delta_bytes)"
    ' \
    "$events_path"
}

runtime_top_stall_command_summary() {
  local runtime_root="$1"
  local events_path="${runtime_root}/automation-events.jsonl"
  jq -Rse -r \
    '
      split("\n")
      | map(select(length > 0) | fromjson?)
      | map(select(.type == "runtime.command_metrics"))
      | sort_by(.details.main_thread_stall_delta_ms | tonumber)
      | last
      | if . == null then
          "n/a"
        else
          "\(.command):delta=\(.details.main_thread_stall_delta_ms)ms before=\(.details.main_thread_stall_before_ms)ms after=\(.details.main_thread_stall_after_ms)ms body=\(.details.command_body_ms)ms wait=\(.details.state_wait_ms)ms total=\(.details.command_total_ms)ms"
        end
    ' \
    "$events_path"
}

runtime_top_stall_phase_summary() {
  local runtime_root="$1"
  local events_path="${runtime_root}/automation-events.jsonl"
  jq -Rse -r \
    '
      split("\n")
      | map(select(length > 0) | fromjson?)
      | map(select(.type == "runtime.phase_marker" and .details.status == "end"))
      | sort_by(.details.main_thread_max_stall_ms | tonumber)
      | last
      | if . == null then
          "n/a"
        else
          "\(.command):\(.details.phase) stall=\(.details.main_thread_max_stall_ms)ms elapsed=\(.details.elapsed_ms // "0")ms"
        end
    ' \
    "$events_path"
}

runtime_command_stall_timeline() {
  local runtime_root="$1"
  local events_path="${runtime_root}/automation-events.jsonl"
  jq -Rse -r \
    '
      split("\n")
      | map(select(length > 0) | fromjson?)
      | map(select(.type == "runtime.command_metrics"))
      | map("\(.command):stall+\(.details.main_thread_stall_delta_ms)ms body=\(.details.command_body_ms)ms wait=\(.details.state_wait_ms)ms total=\(.details.command_total_ms)ms")
      | join(" | ")
    ' \
    "$events_path"
}

runtime_performance_summary() {
  local runtime_root="$1"
  local state_path="${runtime_root}/automation-state.json"
  jq -r '"residentMemoryBytes=\(.resident_memory_bytes // -1) mainThreadMaxStallMs=\(.main_thread_max_stall_ms // -1)"' "$state_path"
}

if [[ "$RUNTIME_QUALITY_ONLY" != "1" ]]; then
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
fi

if [[ "$RUNTIME_QUALITY_CASE" == "1" ]]; then
  if [[ -z "$RUNTIME_QUALITY_FIXTURE_PATH" ]]; then
    RUNTIME_QUALITY_FIXTURE_PATH="${WORK_DIR}/runtime-quality-macos.json"
    fixture_started_at="$(date +%s)"
    write_runtime_quality_fixture "$RUNTIME_QUALITY_FIXTURE_PATH" "$RUNTIME_QUALITY_SCALE"
    fixture_finished_at="$(date +%s)"
    fixture_duration=$((fixture_finished_at - fixture_started_at))
  else
    fixture_duration="prebuilt"
  fi

  runtime_quality_response_assert='.ok == true and .platform == "macos" and (.state.runtime_error_count == 0 or .state.latest_runtime_error_code == "E_APNS_DENIED") and .state.local_store_mode != "unavailable"'
  runtime_quality_state_assert='(.runtime_error_count == 0 or .latest_runtime_error_code == "E_APNS_DENIED") and .local_store_mode != "unavailable"'
  should_stop_after_stage() {
    local stage="$1"
    [[ -n "$RUNTIME_QUALITY_STAGE_STOP" && "$RUNTIME_QUALITY_STAGE_STOP" == "$stage" ]]
  }

  runtime_started_at="$(date +%s)"
  RUNTIME_ROOT="$(mktemp -d /tmp/pushgo-macos-runtime-quality.XXXXXX)"
  run_case \
    "runtime_quality_large_fixture" \
    "{\"id\":\"macos-runtime-quality-large-001\",\"plane\":\"command\",\"name\":\"fixture.seed_messages\",\"args\":{\"path\":\"${RUNTIME_QUALITY_FIXTURE_PATH}\"}}" \
    "${runtime_quality_response_assert} and .state.last_fixture_import_message_count == ${RUNTIME_QUALITY_SCALE}" \
    "${runtime_quality_state_assert} and .last_fixture_import_message_count == ${RUNTIME_QUALITY_SCALE} and .total_message_count > 0 and .runtimequality_tag_count == .total_message_count and .message_tag_option_count >= 2" \
    "$RUNTIME_ROOT"
  runtime_finished_at="$(date +%s)"
  runtime_duration=$((runtime_finished_at - runtime_started_at))
  runtime_metrics="$(runtime_performance_summary "$RUNTIME_ROOT")"
  if should_stop_after_stage "large_fixture"; then
    command_stall_timeline="$(runtime_command_stall_timeline "$RUNTIME_ROOT")"
    top_stall_command="$(runtime_top_stall_command_summary "$RUNTIME_ROOT")"
    top_stall_phase="$(runtime_top_stall_phase_summary "$RUNTIME_ROOT")"
    echo "[runtime-quality-macos] scale=${RUNTIME_QUALITY_SCALE} fixtureGeneration=${fixture_duration}s launchImportListReady=${runtime_duration}s launchMetrics=${runtime_metrics} commandStallTimeline=${command_stall_timeline} topStallCommand=${top_stall_command} topStallPhase=${top_stall_phase}"
    echo "[runtime-quality-macos] stage-stop=${RUNTIME_QUALITY_STAGE_STOP}"
    exit 0
  fi

  query_started_at="$(date +%s)"
  run_case \
    "runtime_quality_message_queries" \
    "{\"id\":\"macos-runtime-quality-message-queries-001\",\"plane\":\"command\",\"name\":\"runtime.measure_message_queries\"}" \
    "${runtime_quality_response_assert}" \
    "${runtime_quality_state_assert}" \
    "$RUNTIME_ROOT"
  assert_runtime_message_queries_event "$RUNTIME_ROOT"
  query_metrics="$(runtime_message_queries_summary "$RUNTIME_ROOT")"
  query_finished_at="$(date +%s)"
  query_duration=$((query_finished_at - query_started_at))
  echo "[runtime-quality-macos-query] ${query_metrics}"
  if should_stop_after_stage "message_queries"; then
    command_stall_timeline="$(runtime_command_stall_timeline "$RUNTIME_ROOT")"
    top_stall_command="$(runtime_top_stall_command_summary "$RUNTIME_ROOT")"
    top_stall_phase="$(runtime_top_stall_phase_summary "$RUNTIME_ROOT")"
    echo "[runtime-quality-macos] scale=${RUNTIME_QUALITY_SCALE} fixtureGeneration=${fixture_duration}s launchImportListReady=${runtime_duration}s launchMetrics=${runtime_metrics} messageQueriesReady=${query_duration}s messageQueryMetrics=${query_metrics} commandStallTimeline=${command_stall_timeline} topStallCommand=${top_stall_command} topStallPhase=${top_stall_phase}"
    echo "[runtime-quality-macos] stage-stop=${RUNTIME_QUALITY_STAGE_STOP}"
    exit 0
  fi

  sort_modes_started_at="$(date +%s)"
  run_case \
    "runtime_quality_sort_modes" \
    "{\"id\":\"macos-runtime-quality-sort-modes-001\",\"plane\":\"command\",\"name\":\"runtime.measure_sort_modes\"}" \
    "${runtime_quality_response_assert}" \
    ".visible_screen == \"screen.messages.list\" and ${runtime_quality_state_assert}" \
    "$RUNTIME_ROOT"
  assert_runtime_sort_modes_event "$RUNTIME_ROOT"
  sort_modes_metrics="$(runtime_sort_modes_summary "$RUNTIME_ROOT")"
  sort_modes_finished_at="$(date +%s)"
  sort_modes_duration=$((sort_modes_finished_at - sort_modes_started_at))
  if should_stop_after_stage "sort_modes"; then
    command_stall_timeline="$(runtime_command_stall_timeline "$RUNTIME_ROOT")"
    top_stall_command="$(runtime_top_stall_command_summary "$RUNTIME_ROOT")"
    top_stall_phase="$(runtime_top_stall_phase_summary "$RUNTIME_ROOT")"
    echo "[runtime-quality-macos] scale=${RUNTIME_QUALITY_SCALE} fixtureGeneration=${fixture_duration}s launchImportListReady=${runtime_duration}s launchMetrics=${runtime_metrics} messageQueriesReady=${query_duration}s messageQueryMetrics=${query_metrics} sortModesReady=${sort_modes_duration}s sortModeMetrics=${sort_modes_metrics} commandStallTimeline=${command_stall_timeline} topStallCommand=${top_stall_command} topStallPhase=${top_stall_phase}"
    echo "[runtime-quality-macos] stage-stop=${RUNTIME_QUALITY_STAGE_STOP}"
    exit 0
  fi

  detail_variants_started_at="$(date +%s)"
  run_case \
    "runtime_quality_detail_variants" \
    "{\"id\":\"macos-runtime-quality-detail-variants-001\",\"plane\":\"command\",\"name\":\"runtime.measure_detail_variants\"}" \
    "${runtime_quality_response_assert}" \
    "(.visible_screen == \"screen.message.detail\" or .visible_screen == \"screen.messages.list\") and ${runtime_quality_state_assert}" \
    "$RUNTIME_ROOT"
  assert_runtime_detail_variants_event "$RUNTIME_ROOT"
  detail_variant_metrics="$(runtime_detail_variants_summary "$RUNTIME_ROOT")"
  detail_variants_finished_at="$(date +%s)"
  detail_variants_duration=$((detail_variants_finished_at - detail_variants_started_at))
  if should_stop_after_stage "detail_variants"; then
    command_stall_timeline="$(runtime_command_stall_timeline "$RUNTIME_ROOT")"
    top_stall_command="$(runtime_top_stall_command_summary "$RUNTIME_ROOT")"
    top_stall_phase="$(runtime_top_stall_phase_summary "$RUNTIME_ROOT")"
    echo "[runtime-quality-macos] scale=${RUNTIME_QUALITY_SCALE} fixtureGeneration=${fixture_duration}s launchImportListReady=${runtime_duration}s launchMetrics=${runtime_metrics} messageQueriesReady=${query_duration}s messageQueryMetrics=${query_metrics} sortModesReady=${sort_modes_duration}s sortModeMetrics=${sort_modes_metrics} detailVariantsReady=${detail_variants_duration}s detailVariantMetrics=${detail_variant_metrics} commandStallTimeline=${command_stall_timeline} topStallCommand=${top_stall_command} topStallPhase=${top_stall_phase}"
    echo "[runtime-quality-macos] stage-stop=${RUNTIME_QUALITY_STAGE_STOP}"
    exit 0
  fi

  media_cycles_started_at="$(date +%s)"
  run_case \
    "runtime_quality_media_cycles" \
    "{\"id\":\"macos-runtime-quality-media-cycles-001\",\"plane\":\"command\",\"name\":\"runtime.measure_media_cycles\"}" \
    "${runtime_quality_response_assert}" \
    ".visible_screen == \"screen.messages.list\" and ${runtime_quality_state_assert}" \
    "$RUNTIME_ROOT"
  assert_runtime_media_cycles_event "$RUNTIME_ROOT"
  media_cycles_metrics="$(runtime_media_cycles_summary "$RUNTIME_ROOT")"
  media_cycles_finished_at="$(date +%s)"
  media_cycles_duration=$((media_cycles_finished_at - media_cycles_started_at))
  if should_stop_after_stage "media_cycles"; then
    command_stall_timeline="$(runtime_command_stall_timeline "$RUNTIME_ROOT")"
    top_stall_command="$(runtime_top_stall_command_summary "$RUNTIME_ROOT")"
    top_stall_phase="$(runtime_top_stall_phase_summary "$RUNTIME_ROOT")"
    echo "[runtime-quality-macos] scale=${RUNTIME_QUALITY_SCALE} fixtureGeneration=${fixture_duration}s launchImportListReady=${runtime_duration}s launchMetrics=${runtime_metrics} messageQueriesReady=${query_duration}s messageQueryMetrics=${query_metrics} sortModesReady=${sort_modes_duration}s sortModeMetrics=${sort_modes_metrics} detailVariantsReady=${detail_variants_duration}s detailVariantMetrics=${detail_variant_metrics} mediaCyclesReady=${media_cycles_duration}s mediaCyclesMetrics=${media_cycles_metrics} commandStallTimeline=${command_stall_timeline} topStallCommand=${top_stall_command} topStallPhase=${top_stall_phase}"
    echo "[runtime-quality-macos] stage-stop=${RUNTIME_QUALITY_STAGE_STOP}"
    exit 0
  fi

  detail_release_started_at="$(date +%s)"
  run_case \
    "runtime_quality_detail_release_cycles" \
    "{\"id\":\"macos-runtime-quality-detail-release-001\",\"plane\":\"command\",\"name\":\"runtime.measure_detail_release_cycles\"}" \
    "${runtime_quality_response_assert}" \
    ".visible_screen == \"screen.messages.list\" and ${runtime_quality_state_assert}" \
    "$RUNTIME_ROOT"
  assert_runtime_detail_release_cycles_event "$RUNTIME_ROOT"
  detail_release_metrics="$(runtime_detail_release_cycles_summary "$RUNTIME_ROOT")"
  detail_release_finished_at="$(date +%s)"
  detail_release_duration=$((detail_release_finished_at - detail_release_started_at))
  if should_stop_after_stage "detail_release_cycles"; then
    command_stall_timeline="$(runtime_command_stall_timeline "$RUNTIME_ROOT")"
    top_stall_command="$(runtime_top_stall_command_summary "$RUNTIME_ROOT")"
    top_stall_phase="$(runtime_top_stall_phase_summary "$RUNTIME_ROOT")"
    echo "[runtime-quality-macos] scale=${RUNTIME_QUALITY_SCALE} fixtureGeneration=${fixture_duration}s launchImportListReady=${runtime_duration}s launchMetrics=${runtime_metrics} messageQueriesReady=${query_duration}s messageQueryMetrics=${query_metrics} sortModesReady=${sort_modes_duration}s sortModeMetrics=${sort_modes_metrics} detailVariantsReady=${detail_variants_duration}s detailVariantMetrics=${detail_variant_metrics} mediaCyclesReady=${media_cycles_duration}s mediaCyclesMetrics=${media_cycles_metrics} detailReleaseReady=${detail_release_duration}s detailReleaseMetrics=${detail_release_metrics} commandStallTimeline=${command_stall_timeline} topStallCommand=${top_stall_command} topStallPhase=${top_stall_phase}"
    echo "[runtime-quality-macos] stage-stop=${RUNTIME_QUALITY_STAGE_STOP}"
    exit 0
  fi

  window_resize_started_at="$(date +%s)"
  run_case \
    "runtime_quality_window_resize" \
    "{\"id\":\"macos-runtime-quality-window-resize-001\",\"plane\":\"command\",\"name\":\"runtime.measure_window_resize\"}" \
    "${runtime_quality_response_assert}" \
    ".visible_screen == \"screen.message.detail\" and .opened_message_id == \"runtime-ui-msg-0\" and ${runtime_quality_state_assert}" \
    "$RUNTIME_ROOT"
  assert_runtime_window_resize_event "$RUNTIME_ROOT"
  window_resize_metrics="$(runtime_window_resize_summary "$RUNTIME_ROOT")"
  window_resize_finished_at="$(date +%s)"
  window_resize_duration=$((window_resize_finished_at - window_resize_started_at))

  detail_started_at="$(date +%s)"
  run_case \
    "runtime_quality_message_detail" \
    "{\"id\":\"macos-runtime-quality-detail-001\",\"plane\":\"command\",\"name\":\"message.open\",\"args\":{\"message_id\":\"runtime-ui-msg-0\"}}" \
    "${runtime_quality_response_assert}" \
    ".visible_screen == \"screen.message.detail\" and .opened_message_id == \"runtime-ui-msg-0\" and ${runtime_quality_state_assert}" \
    "$RUNTIME_ROOT"
  detail_finished_at="$(date +%s)"
  detail_duration=$((detail_finished_at - detail_started_at))
  detail_metrics="$(runtime_performance_summary "$RUNTIME_ROOT")"

  event_detail_started_at="$(date +%s)"
  run_case \
    "runtime_quality_event_detail" \
    "{\"id\":\"macos-runtime-quality-event-detail-001\",\"plane\":\"command\",\"name\":\"entity.open\",\"args\":{\"entity_type\":\"event\",\"entity_id\":\"event-runtime-1\"}}" \
    "${runtime_quality_response_assert}" \
    ".visible_screen == \"screen.events.detail\" and .opened_entity_type == \"event\" and .opened_entity_id == \"event-runtime-1\" and ${runtime_quality_state_assert}" \
    "$RUNTIME_ROOT"
  event_detail_finished_at="$(date +%s)"
  event_detail_duration=$((event_detail_finished_at - event_detail_started_at))
  event_detail_metrics="$(runtime_performance_summary "$RUNTIME_ROOT")"

  thing_detail_started_at="$(date +%s)"
  run_case \
    "runtime_quality_thing_detail" \
    "{\"id\":\"macos-runtime-quality-thing-detail-001\",\"plane\":\"command\",\"name\":\"entity.open\",\"args\":{\"entity_type\":\"thing\",\"entity_id\":\"thing-runtime-2\"}}" \
    "${runtime_quality_response_assert}" \
    ".visible_screen == \"screen.things.detail\" and .opened_entity_type == \"thing\" and .opened_entity_id == \"thing-runtime-2\" and ${runtime_quality_state_assert}" \
    "$RUNTIME_ROOT"
  thing_detail_finished_at="$(date +%s)"
  thing_detail_duration=$((thing_detail_finished_at - thing_detail_started_at))
  thing_detail_metrics="$(runtime_performance_summary "$RUNTIME_ROOT")"
  command_stall_timeline="$(runtime_command_stall_timeline "$RUNTIME_ROOT")"
  top_stall_command="$(runtime_top_stall_command_summary "$RUNTIME_ROOT")"
  top_stall_phase="$(runtime_top_stall_phase_summary "$RUNTIME_ROOT")"
  echo "[runtime-quality-macos] scale=${RUNTIME_QUALITY_SCALE} fixtureGeneration=${fixture_duration}s launchImportListReady=${runtime_duration}s launchMetrics=${runtime_metrics} messageQueriesReady=${query_duration}s sortModesReady=${sort_modes_duration}s sortModeMetrics=${sort_modes_metrics} detailVariantsReady=${detail_variants_duration}s detailVariantMetrics=${detail_variant_metrics} mediaCyclesReady=${media_cycles_duration}s mediaCyclesMetrics=${media_cycles_metrics} detailReleaseReady=${detail_release_duration}s detailReleaseMetrics=${detail_release_metrics} windowResizeReady=${window_resize_duration}s windowResizeMetrics=${window_resize_metrics} messageDetailReady=${detail_duration}s messageDetailMetrics=${detail_metrics} eventDetailReady=${event_detail_duration}s eventDetailMetrics=${event_detail_metrics} thingDetailReady=${thing_detail_duration}s thingDetailMetrics=${thing_detail_metrics} commandStallTimeline=${command_stall_timeline} topStallCommand=${top_stall_command} topStallPhase=${top_stall_phase}"
fi

echo "[macos-smoke] all cases passed"
