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
apple_ui_lease_file="${PUSHGO_APPLE_UI_LEASE_FILE:-$repo_root/build/.pushgo-apple-ui-tests.lock}"

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

xcrun simctl shutdown "$target" >/dev/null 2>&1 || true
xcrun simctl boot "$target" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$target" -b

requested_content_size="${QUALITY_CONTENT_SIZE:-}"
original_content_size=""
restore_content_size() {
  local command_status=$?
  local restored_content_size=""
  local restore_failed=0
  trap - EXIT
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
  exit "$command_status"
}
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
  trap restore_content_size EXIT
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
  # Xcode otherwise races its own terminate-and-relaunch operation when a prior
  # UI-test process is still registered with CoreSimulator. Terminate it as an
  # explicit preparation step; absence is already the desired state.
  xcrun simctl terminate "$target" "$app_bundle_identifier" >/dev/null 2>&1 || true
  set +e
  xcodebuild "${common_args[@]}" -resultBundlePath "$result_bundle" test-without-building 2>&1 | tee "$logfile"
  local status=${PIPESTATUS[0]}
  set -e
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
    xcrun simctl shutdown "$target" >/dev/null 2>&1 || true
    xcrun simctl boot "$target" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "$target" -b
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
