#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
project_path="${PROJECT_PATH:-$repo_root/pushgo.xcodeproj}"
scheme="${SCHEME:-PushGo-iOS}"
app_bundle_identifier="${APP_BUNDLE_IDENTIFIER:-io.ethan.pushgo}"
test_scopes="${TEST_SCOPES:-${TEST_SCOPE:-}}"
expected_test_count="${QUALITY_EXPECTED_TEST_COUNT:-}"
max_retries="${MAX_RETRIES:-0}"
derived_data_path="${DERIVED_DATA_PATH:-$repo_root/.deriveddata-ui-tests}"
results_root="${RESULTS_ROOT:-$repo_root/build/quality-results/ios}"
runner_status_file="${QUALITY_RUNNER_STATUS_FILE:-}"
runner_issue_file="${QUALITY_RUNNER_ISSUE_FILE:-}"
reuse_built_tests="${QUALITY_REUSE_BUILT_TESTS:-0}"
allow_expected_failures="${QUALITY_ALLOW_EXPECTED_FAILURES:-0}"
simulator_lifecycle="${QUALITY_IOS_SIMULATOR_LIFECYCLE:-cold}"
apple_ui_lease_file="${PUSHGO_APPLE_UI_LEASE_FILE:-$repo_root/build/.pushgo-apple-ui-tests.lock}"
problem_reporter_cleaner="$repo_root/scripts/close_macos_problem_reporter.sh"
problem_reporter_monitor_pid=""
problem_reporter_monitor_log=""
requested_content_size="${QUALITY_CONTENT_SIZE:-}"
original_content_size=""

if [[ ! "$max_retries" =~ ^[0-9]+$ ]] || (( max_retries != 0 )); then
  echo "status=BLOCKED"
  echo "reason=ios_ui_retries_are_disabled:$max_retries"
  exit 2
fi
if [[ -n "$expected_test_count" && ! "$expected_test_count" =~ ^[1-9][0-9]*$ ]]; then
  echo "status=BLOCKED"
  echo "reason=invalid_expected_ios_test_count:$expected_test_count"
  exit 2
fi

if [[ "$reuse_built_tests" != "0" && "$reuse_built_tests" != "1" ]]; then
  echo "status=BLOCKED"
  echo "reason=invalid_ios_reuse_built_tests:$reuse_built_tests"
  exit 2
fi
if [[ "$allow_expected_failures" != "0" && "$allow_expected_failures" != "1" ]]; then
  echo "status=BLOCKED"
  echo "reason=invalid_ios_allow_expected_failures:$allow_expected_failures"
  exit 2
fi
case "$simulator_lifecycle" in
  cold|warm) ;;
  *)
    echo "status=BLOCKED"
    echo "reason=invalid_ios_simulator_lifecycle:$simulator_lifecycle"
    exit 2
    ;;
esac

# These XCTest methods do not manufacture a notification themselves. Their
# companion runner waits for the App-owned background readiness contract and
# injects the exact payload through the Simulator before it evaluates the user
# route. Running them here produces a false product failure (no card was ever
# delivered), so reject the invalid harness selection before taking the Apple
# UI lease or touching the dedicated Simulator.
if [[ -n "$test_scopes" ]]; then
  IFS=',' read -r -a requested_scope_list <<< "$test_scopes"
  for requested_scope in "${requested_scope_list[@]}"; do
    if [[ "$requested_scope" == PushGo-iOSUITests/PushGo_iOSSystemNotificationTests* ]]; then
      echo "status=BLOCKED"
      echo "reason=ios_system_notification_scope_requires_dedicated_runner"
      exit 2
    fi
  done
fi

# iOS and macOS UI builds can saturate the same host and make macOS launch hit
# the scene-create watchdog. Fail as a test-system resource conflict instead of
# manufacturing a product crash. This lease is PushGo-local and never touches
# another repository's devices or DerivedData.
mkdir -p "$(dirname "$apple_ui_lease_file")"
exec 9>"$apple_ui_lease_file"
if ! /usr/bin/lockf -s -t 0 9; then
  echo "status=BLOCKED"
  echo "reason=pushgo_apple_ui_lease_busy"
  exit 2
fi

if [[ -n "$runner_status_file" && ! -f "$runner_status_file" ]]; then
  mkdir -p "$(dirname "$runner_status_file")"
  printf 'PASSED\n' > "$runner_status_file"
fi

"$repo_root/scripts/require_unlocked_apple_ui_console.sh" ios_simulator
python3 "$repo_root/scripts/quality_test_system_issues.py" --check

doctor_output="$("$repo_root/scripts/quality_doctor.sh")"
printf '%s\n' "$doctor_output"
target="$(printf '%s\n' "$doctor_output" | awk -F= '$1 == "simulator_id" { print $2; exit }')"
if [[ -z "$target" ]]; then
  echo "status=BLOCKED"
  echo "reason=no_available_ios_simulator"
  exit 2
fi

mkdir -p "$results_root"

finish() {
  local command_status=$?
  trap - EXIT INT TERM
  local restored_content_size=""
  local restore_failed=0
  if [[ -n "$original_content_size" ]]; then
    if ! xcrun simctl ui "$target" content_size "$original_content_size" >/dev/null 2>&1; then
      restore_failed=1
    else
      restored_content_size="$(xcrun simctl ui "$target" content_size 2>/dev/null || true)"
      [[ "$restored_content_size" == "$original_content_size" ]] || restore_failed=1
    fi
  fi
  if [[ $restore_failed -ne 0 ]]; then
    echo "status=BLOCKED"
    echo "reason=ios_content_size_restore_failed:${restored_content_size:-unreadable}"
    if [[ -n "$runner_status_file" ]]; then
      printf 'BLOCKED\n' > "$runner_status_file"
    fi
    if [[ $command_status -eq 0 ]]; then
      command_status=2
    fi
  fi
  if [[ -n "$problem_reporter_monitor_pid" ]]; then
    kill "$problem_reporter_monitor_pid" >/dev/null 2>&1 || true
    wait "$problem_reporter_monitor_pid" 2>/dev/null || true
  fi
  # Close only the exact host crash-reporter processes. This removes a
  # blocking dialog after an App/Simulator crash without killing Simulator,
  # CoreSimulator, or any unrelated application; the original result/log has
  # already been retained and remains the source of the failure classification.
  "$problem_reporter_cleaner" || true
  if [[ -n "$problem_reporter_monitor_log" ]]; then
    rm -f "$problem_reporter_monitor_log"
  fi
  exit "$command_status"
}
trap finish EXIT INT TERM

# A stale host crash dialog must not cover the next iOS journey. Keep the
# watcher alive for the whole batch so a delayed report created by a simulator
# service (for example PosterBoard) is closed before the following test starts.
"$problem_reporter_cleaner" || true
problem_reporter_monitor_log="$(mktemp -t pushgo-ios-problem-reporter-monitor.XXXXXX.log)"
"$problem_reporter_cleaner" --watch-pid "$$" \
  >>"$problem_reporter_monitor_log" 2>&1 9>&- &
problem_reporter_monitor_pid=$!

common_args=(
  -project "$project_path"
  -scheme "$scheme"
  -configuration Debug
  -derivedDataPath "$derived_data_path"
  -destination "platform=iOS Simulator,id=${target}"
  -onlyUsePackageVersionsFromResolvedFile
  -disableAutomaticPackageResolution
  -skipPackageUpdates
  -parallel-testing-enabled NO
  -maximum-parallel-testing-workers 1
  -collect-test-diagnostics never
)

if [[ -n "$test_scopes" ]]; then
  IFS=',' read -r -a scope_list <<< "$test_scopes"
  for scope in "${scope_list[@]}"; do
    [[ -n "$scope" ]] && common_args+=("-only-testing:${scope}")
  done
fi

channel_copy_scope="PushGo-iOSUITests/PushGo_iOSUITests/testChannelCreateRenameAndBothUnsubscribeOutcomesPersist"
channel_copy_expected="01H00000000000000000000003"
observe_channel_copy=0
if [[ -z "$test_scopes" ]]; then
  observe_channel_copy=1
else
  for scope in "${scope_list[@]}"; do
    case "$scope" in
      PushGo-iOSUITests|PushGo-iOSUITests/PushGo_iOSUITests|"$channel_copy_scope")
        observe_channel_copy=1
        ;;
    esac
  done
fi

prepare_simulator() {
  if [[ "$simulator_lifecycle" == "cold" ]]; then
    # Cold boot remains the default hermetic boundary. It is intentionally
    # scoped to the selected PushGo device; no global CoreSimulator operation is
    # allowed here.
    xcrun simctl shutdown "$target" >/dev/null 2>&1 || true
    xcrun simctl boot "$target" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "$target" -b
  else
    # Warm mode is an explicit A/B diagnostic and never silently falls back to a
    # cold boot. Reusing a booted dedicated device avoids restarting Apple
    # Simulator daemons (including PosterBoard) while retaining app installation,
    # App-owned readiness and all product-level Oracles below.
    if ! xcrun simctl list devices | awk -v target="$target" '$0 ~ target && $0 ~ /Booted/ { found = 1 } END { exit(found ? 0 : 1) }'; then
      echo "status=BLOCKED"
      echo "reason=ios_warm_simulator_not_booted:$target"
      exit 2
    fi
    xcrun simctl bootstatus "$target" -b
  fi
}

prepare_simulator
echo "ios_simulator_lifecycle=$simulator_lifecycle"

if [[ -n "$requested_content_size" ]]; then
  case "$requested_content_size" in
    extra-small|small|medium|large|extra-large|extra-extra-large|extra-extra-extra-large|accessibility-medium|accessibility-large|accessibility-extra-large|accessibility-extra-extra-large|accessibility-extra-extra-extra-large) ;;
    *)
      echo "status=BLOCKED"
      echo "reason=unsupported_ios_content_size:$requested_content_size"
      exit 2
      ;;
  esac
  original_content_size="$(xcrun simctl ui "$target" content_size)"
  case "$original_content_size" in
    extra-small|small|medium|large|extra-large|extra-extra-large|extra-extra-extra-large|accessibility-medium|accessibility-large|accessibility-extra-large|accessibility-extra-extra-large|accessibility-extra-extra-extra-large) ;;
    *)
      echo "status=BLOCKED"
      echo "reason=unable_to_capture_ios_content_size:$original_content_size"
      exit 2
      ;;
  esac
  xcrun simctl ui "$target" content_size "$requested_content_size"
  applied_content_size="$(xcrun simctl ui "$target" content_size)"
  [[ "$applied_content_size" == "$requested_content_size" ]] || {
    echo "status=BLOCKED"
    echo "reason=ios_content_size_not_applied:$applied_content_size"
    exit 2
  }
  echo "content_size=$applied_content_size"
fi

app_bundle="$derived_data_path/Build/Products/Debug-iphonesimulator/PushGo.app"
test_runner_bundle="$derived_data_path/Build/Products/Debug-iphonesimulator/PushGo-iOSUITests-Runner.app"
if [[ "$reuse_built_tests" == "1" ]]; then
  [[ -d "$app_bundle" && -d "$test_runner_bundle" ]] || {
    echo "status=BLOCKED"
    echo "reason=ios_reusable_built_tests_missing"
    exit 2
  }
  echo "==> reuse build-for-testing products"
else
  echo "==> build-for-testing"
  xcodebuild "${common_args[@]}" build-for-testing
fi

if ! "$repo_root/scripts/prepare_ios_ui_test_app.sh" "$target" "$app_bundle" "$app_bundle_identifier"; then
  [[ -z "$runner_status_file" ]] || printf 'BLOCKED\n' > "$runner_status_file"
  exit 2
fi

run_test_once() {
  local logfile="$1"
  local result_bundle="$2"
  local pasteboard_oracle_dir=""
  local pasteboard_oracle_pid=""
  # Xcode otherwise races its own terminate-and-relaunch operation when a prior
  # UI-test process is still registered with CoreSimulator. Terminate it as an
  # explicit preparation step; absence is already the desired state.
  xcrun simctl terminate "$target" "$app_bundle_identifier" >/dev/null 2>&1 || true
  if [[ "$observe_channel_copy" == "1" ]]; then
    pasteboard_oracle_dir="$(mktemp -d -t pushgo-ios-pasteboard-oracle.XXXXXX)"
    printf '%s' "pushgo-quality-sentinel-$(uuidgen)" | xcrun simctl pbcopy "$target"
    (
      while [[ ! -f "$pasteboard_oracle_dir/stop" ]]; do
        if [[ "$(xcrun simctl pbpaste "$target" 2>/dev/null || true)" == "$channel_copy_expected" ]]; then
          printf 'PASSED\n' > "$pasteboard_oracle_dir/passed"
          exit 0
        fi
        sleep 0.2
      done
    ) 9>&- &
    pasteboard_oracle_pid=$!
  fi
  set +e
  xcodebuild "${common_args[@]}" -resultBundlePath "$result_bundle" test-without-building 2>&1 | tee "$logfile"
  local status=${PIPESTATUS[0]}
  set -e

  if [[ "$observe_channel_copy" == "1" ]]; then
    touch "$pasteboard_oracle_dir/stop"
    wait "$pasteboard_oracle_pid" 2>/dev/null || true
    if [[ $status -eq 0 && ! -f "$pasteboard_oracle_dir/passed" ]]; then
      printf '%s\n' \
        "FAILED: the real Channel copy action never exposed its exact canonical ID through the Simulator system pasteboard" \
        | tee -a "$logfile"
      status=1
    elif [[ $status -eq 0 ]]; then
      echo "external_pasteboard_oracle=PASSED"
    fi
    rm -rf "$pasteboard_oracle_dir"
  fi

  if ! kill -0 "$problem_reporter_monitor_pid" >/dev/null 2>&1; then
    local monitor_status=0
    wait "$problem_reporter_monitor_pid" || monitor_status=$?
    [[ -z "$runner_status_file" ]] || printf 'BLOCKED\n' > "$runner_status_file"
    echo "status=BLOCKED"
    echo "reason=ios_problem_reporter_cleanup_failed:${monitor_status}"
    echo "monitor_log=$problem_reporter_monitor_log"
    echo "log=$logfile"
    echo "result_bundle=$result_bundle"
    exit 2
  fi
  return "$status"
}

attempt=1
until [[ $attempt -gt $((max_retries + 1)) ]]; do
  log_file="$(mktemp -t pushgo-ui-tests.XXXXXX.log)"
  result_bundle="$results_root/run-${attempt}-$(date +%Y%m%d-%H%M%S).xcresult"
  echo "==> test-without-building (attempt ${attempt}/$((max_retries + 1)))"

  if run_test_once "$log_file" "$result_bundle"; then
    verify_execution_args=(--result-bundle "$result_bundle")
    [[ "$allow_expected_failures" == "0" ]] || verify_execution_args+=(--allow-expected-failures)
    [[ -z "$expected_test_count" ]] || verify_execution_args+=(--expected-test-count "$expected_test_count")
    if ! python3 "$repo_root/scripts/verify_apple_test_execution.py" "${verify_execution_args[@]}"; then
      [[ -z "$runner_status_file" ]] || printf 'FAILED\n' > "$runner_status_file"
      echo "status=FAILED_TEST_SYSTEM"
      echo "reason=apple_test_execution_receipt_rejected"
      echo "result_bundle=$result_bundle"
      exit 3
    fi
    if ! python3 "$repo_root/scripts/verify_apple_test_execution.py" "${verify_execution_args[@]}" --reject-runtime-warnings; then
      if classification="$(python3 "$repo_root/scripts/quality_test_system_issues.py" --match-file "$log_file")"; then
        printf '%s\n' "$classification"
        issue_ids="$(printf '%s\n' "$classification" | sed -n 's/^classification_issue_ids=//p')"
        if [[ -n "$runner_issue_file" && -n "$issue_ids" ]]; then
          printf '%s\n' "$issue_ids" | tr ',' '\n' >> "$runner_issue_file"
        fi
        [[ -z "$runner_status_file" ]] || printf 'FLAKY\n' > "$runner_status_file"
        echo "status=FLAKY"
        echo "reason=registered_apple_runtime_warning"
        echo "result_bundle=$result_bundle"
        exit 0
      fi
      [[ -z "$runner_status_file" ]] || printf 'FAILED\n' > "$runner_status_file"
      echo "status=FAILED_TEST_SYSTEM"
      echo "reason=unknown_apple_runtime_warning"
      echo "result_bundle=$result_bundle"
      exit 3
    fi
    rm -f "$log_file"
    echo "status=PASSED"
    echo "result_bundle=$result_bundle"
    exit 0
  fi

  if classification="$(python3 "$repo_root/scripts/quality_test_system_issues.py" --match-file "$log_file" --reject-if-matches "Test Case '-\\[" --retryable-only)"; then
    printf '%s\n' "$classification"
    issue_ids="$(printf '%s\n' "$classification" | sed -n 's/^classification_issue_ids=//p')"
    allowed_retries="$(printf '%s\n' "$classification" | sed -n 's/^allowed_retries=//p')"
    [[ "$allowed_retries" =~ ^[0-9]+$ ]] && (( max_retries <= allowed_retries )) || {
      echo "status=BLOCKED"
      echo "reason=runner_retry_exceeds_registered_allowance:$max_retries:$allowed_retries"
      exit 2
    }
    if [[ -n "$runner_issue_file" && -n "$issue_ids" ]]; then
      printf '%s\n' "$issue_ids" | tr ',' '\n' >> "$runner_issue_file"
    fi
    if [[ -n "$runner_status_file" ]]; then
      if [[ $attempt -le $max_retries ]]; then
        printf 'FLAKY\n' > "$runner_status_file"
      else
        printf 'BLOCKED\n' > "$runner_status_file"
      fi
    fi
    if [[ $attempt -gt $max_retries ]]; then
      echo "status=BLOCKED"
      echo "reason=transient_runner_failure_exhausted_retries"
      echo "log=$log_file"
      echo "result_bundle=$result_bundle"
      exit 2
    fi
    prepare_simulator
    rm -f "$log_file"
    attempt=$((attempt + 1))
    continue
  fi

  # An App-owned readiness failure happens inside XCTest, so the generic
  # "no Test Case has started" runner-flake guard intentionally cannot see it.
  # It is a zero-retry precondition boundary, never a product assertion and
  # never a route to a green result.
  if classification="$(python3 "$repo_root/scripts/quality_test_system_issues.py" --match-file "$log_file")" \
    && printf '%s\n' "$classification" | grep -q 'classification_issue_ids=.*apple-quality-precondition'; then
    printf '%s\n' "$classification"
    issue_ids="$(printf '%s\n' "$classification" | sed -n 's/^classification_issue_ids=//p')"
    if [[ -n "$runner_issue_file" && -n "$issue_ids" ]]; then
      printf '%s\n' "$issue_ids" | tr ',' '\n' >> "$runner_issue_file"
    fi
    if [[ -n "$runner_status_file" ]]; then
      printf 'BLOCKED\n' > "$runner_status_file"
    fi
    echo "status=BLOCKED"
    echo "reason=app_owned_quality_precondition_failed"
    echo "log=$log_file"
    echo "result_bundle=$result_bundle"
    exit 2
  fi

  # XCTest may have announced a Test Case before its own app-launch operation
  # fails. This exact Xcode/CoreSimulator failure is still a preparation fault:
  # no product UI or business action was reachable, so it must not be reported
  # as a product assertion and must never be retried into green.
  if grep -q "Application launch for '.*' did not return a process handle nor launch error" "$log_file"; then
    if [[ -n "$runner_status_file" ]]; then
      printf 'BLOCKED\n' > "$runner_status_file"
    fi
    echo "status=BLOCKED"
    echo "reason=ios_app_launch_precondition_failed"
    echo "log=$log_file"
    echo "result_bundle=$result_bundle"
    exit 2
  fi

  if ! grep -q "Test Case '-\\[" "$log_file"; then
    if [[ -n "$runner_status_file" ]]; then
      printf 'BLOCKED\n' > "$runner_status_file"
    fi
    echo "status=BLOCKED"
    echo "reason=unclassified_runner_failure_before_product_action"
    echo "log=$log_file"
    echo "result_bundle=$result_bundle"
    exit 2
  fi

  echo "status=FAILED"
  echo "log=$log_file"
  echo "result_bundle=$result_bundle"
  exit 1
done
