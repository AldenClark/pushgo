#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
project_path="${PROJECT_PATH:-$repo_root/pushgo.xcodeproj}"
scheme="${SCHEME:-PushGo-iOS}"
app_bundle_identifier="${APP_BUNDLE_IDENTIFIER:-io.ethan.pushgo}"
test_scopes="${TEST_SCOPES:-${TEST_SCOPE:-}}"
max_retries="${MAX_RETRIES:-0}"
derived_data_path="${DERIVED_DATA_PATH:-$repo_root/.deriveddata-ui-tests}"
results_root="${RESULTS_ROOT:-$repo_root/build/quality-results/ios}"
runner_status_file="${QUALITY_RUNNER_STATUS_FILE:-}"
runner_issue_file="${QUALITY_RUNNER_ISSUE_FILE:-}"

if [[ ! "$max_retries" =~ ^[0-9]+$ ]] || (( max_retries != 0 )); then
  echo "status=BLOCKED"
  echo "reason=ios_ui_retries_are_disabled:$max_retries"
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

echo "==> build-for-testing"
xcodebuild "${common_args[@]}" build-for-testing

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
