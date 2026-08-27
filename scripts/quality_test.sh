#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lane="${1:-pr}"
results_root="$repo_root/build/quality-results"
result_file="$results_root/apple-$lane-summary.json"
runner_status_file="$results_root/apple-$lane-runner-status.txt"
mkdir -p "$results_root"
rm -f "$runner_status_file"

claims=()
selected_claims=()
not_run=(
  "physical APNs/notification/permission/system-surface evidence"
  "opt-in 100k Store/watch/concurrency performance evidence"
)

write_result() {
  local product_status="$1"
  local test_system_status="$2"
  local reason="${3:-}"
  local args=(
    --output "$result_file"
    --platform apple
    --lane "$lane"
    --product-status "$product_status"
    --test-system-status "$test_system_status"
  )
  local item
  for item in "${selected_claims[@]}"; do args+=(--selected-claim "$item"); done
  for item in "${claims[@]}"; do args+=(--claim "$item"); done
  for item in "${not_run[@]}"; do args+=(--not-run "$item"); done
  [[ -z "$reason" ]] || args+=(--reason "$reason")
  python3 "$repo_root/scripts/quality_result.py" "${args[@]}"
}

on_exit() {
  local status=$?
  if [[ $status -eq 0 ]]; then
    local runner_status="PASSED"
    [[ ! -f "$runner_status_file" ]] || runner_status="$(<"$runner_status_file")"
    write_result PASSED "$runner_status"
  elif [[ $status -eq 2 ]]; then
    write_result NOT_RUN BLOCKED "lane preparation was blocked before product evidence completed"
  else
    write_result FAILED PASSED "an executed product oracle failed; inspect xcresult/log for the first failure"
  fi
  printf 'quality_result=%s\n' "$result_file"
}
trap on_exit EXIT

run_impact_contracts() {
  local plan_path="${QUALITY_IMPACT_PLAN:-}"
  local check
  local checks_output
  if ! checks_output="$(
    python3 - "$plan_path" "$lane" <<'PY'
import json
import pathlib
import sys

plan_path, lane = sys.argv[1:]
checks = set()
if plan_path:
    path = pathlib.Path(plan_path)
    if not path.is_file():
        raise SystemExit(f"impact plan is not a regular file: {path}")
    checks.update(json.loads(path.read_text()).get("required_checks", []))
if lane == "release":
    checks.update({"apple-release-static-contract", "apple-update-distribution-contract"})
print("\n".join(sorted(checks)))
PY
  )"; then
    echo "status=BLOCKED"
    echo "reason=invalid_apple_impact_plan"
    exit 2
  fi
  while IFS= read -r check; do
    [[ -n "$check" ]] || continue
    case "$check" in
      apple-update-distribution-contract)
        selected_claims+=("Apple Sparkle/App Store update distribution contract")
        python3 "$repo_root/scripts/verify_update_distribution.py" \
          --appcast "$repo_root/release/appcast.xml" \
          --app-store "$repo_root/release/appstore.json" \
          --update-notes "$repo_root/release/update-notes"
        claims+=("Apple Sparkle/App Store update distribution contract")
        ;;
      apple-release-static-contract)
        selected_claims+=("Apple locked dependency/privacy/release/rollback static contracts")
        "$repo_root/scripts/verify_locked_packages.sh"
        "$repo_root/scripts/verify_privacy_manifests.sh"
        python3 "$repo_root/scripts/verify_release_workflow_security.py"
        python3 "$repo_root/scripts/verify_release_distribution_contract.py"
        "$repo_root/scripts/verify_rollback_compatibility.sh"
        claims+=("Apple locked dependency/privacy/release/rollback static contracts")
        ;;
      *)
        echo "status=BLOCKED"
        echo "reason=unsupported_apple_impact_check:$check"
        exit 2
        ;;
    esac
  done <<< "$checks_output"
}

run_impact_contracts

core_ui_scopes="PushGo-iOSUITests/PushGo_iOSUITests/testQualitySessionUsesAppOwnedStoreAndReachesFunctionalEmptyState,PushGo-iOSUITests/PushGo_iOSUITests/testQualityStandardMessagesShowAccurateContentAndSurviveRelaunch,PushGo-iOSUITests/PushGo_iOSUITests/testQualityMessageWorkflowLoadsSecondPageAndPersistsReadActions,PushGo-iOSUITests/PushGo_iOSUITests/testQualityMessageSearchReturnsOnlyTheTargetAndOpensItsRealDetail,PushGo-iOSUITests/PushGo_iOSUITests/testQualityMessageDeleteUndoRestoresTheSameObjectAcrossRelaunch,PushGo-iOSUITests/PushGo_iOSUITests/testSlowMessageLoadBecomesVisibleBeforeDataCompletes,PushGo-iOSUITests/PushGo_iOSUITests/testSlowMessageRefreshKeepsAccurateContentVisibleUntilCompletion,PushGo-iOSUITests/PushGo_iOSUITests/testMessageRefreshPersistsNewProviderResultAndOpensItsRealDetail,PushGo-iOSUITests/PushGo_iOSUITests/testMessageRefreshFailureKeepsSnapshotAndRetryRecoversPersistedResult,PushGo-iOSUITests/PushGo_iOSUITests/testMessageLoadFailureShowsRetryAndRecoversToRealDataState"
nightly_ui_scopes="$core_ui_scopes,PushGo-iOSUITests/PushGo_iOSUITests/testQualityPrimaryNavigationUsesRealControlsAndReachesEachProductScreen,PushGo-iOSUITests/PushGo_iOSUITests/testEventClosePersistsAndOngoingFilterReflectsRealProjection,PushGo-iOSUITests/PushGo_iOSUITests/testImportedThingFixtureCanOpenThingDetail,PushGo-iOSUITests/PushGo_iOSUITests/testInvalidServerAddressShowsInlineFeedbackInsteadOfToast"

run_core() {
  selected_claims+=("Apple Core/Store/integration suite")
  "$repo_root/scripts/quality_doctor.sh"
  swift test --package-path "$repo_root"
  claims+=("Apple Core/Store/integration suite")
}

case "$lane" in
  focused)
    focused_scopes="${TEST_SCOPES:-${TEST_SCOPE:-}}"
    [[ -n "$focused_scopes" ]] || {
      echo "status=BLOCKED"
      echo "reason=focused_lane_requires_TEST_SCOPES"
      exit 2
    }
    selected_claims+=("focused iOS UI: $focused_scopes")
    QUALITY_RUNNER_STATUS_FILE="$runner_status_file" "$repo_root/scripts/run_ios_ui_tests.sh"
    claims+=("focused iOS UI: $focused_scopes")
    ;;
  pr)
    run_core
    selected_claims+=("iOS core message empty/content/pagination/read/search/delete/slow-load/slow-refresh/new-result/refresh-recovery/error-retry journeys")
    TEST_SCOPES="${TEST_SCOPES:-$core_ui_scopes}" \
      MAX_RETRIES="${MAX_RETRIES:-1}" \
      QUALITY_RUNNER_STATUS_FILE="$runner_status_file" "$repo_root/scripts/run_ios_ui_tests.sh"
    claims+=("iOS core message empty/content/pagination/read/search/delete/slow-load/slow-refresh/new-result/refresh-recovery/error-retry journeys")
    ;;
  nightly)
    run_core
    selected_claims+=("iOS core message journeys plus navigation/Event/Thing/server-validation representatives")
    TEST_SCOPES="${TEST_SCOPES:-$nightly_ui_scopes}" \
      MAX_RETRIES="${MAX_RETRIES:-1}" \
      QUALITY_RUNNER_STATUS_FILE="$runner_status_file" "$repo_root/scripts/run_ios_ui_tests.sh"
    claims+=("iOS core message journeys plus navigation/Event/Thing/server-validation representatives")
    ;;
  release)
    run_core
    selected_claims+=("iOS release-lane representative journeys")
    TEST_SCOPES="${TEST_SCOPES:-$nightly_ui_scopes}" \
      MAX_RETRIES="${MAX_RETRIES:-1}" \
      QUALITY_RUNNER_STATUS_FILE="$runner_status_file" "$repo_root/scripts/run_ios_ui_tests.sh"
    claims+=("iOS release-lane representative journeys")
    selected_claims+=("iOS Release build and Quality Runtime isolation")
    xcodebuild \
      -project "$repo_root/pushgo.xcodeproj" \
      -scheme PushGo-iOS \
      -configuration Release \
      -destination 'generic/platform=iOS Simulator' \
      -onlyUsePackageVersionsFromResolvedFile \
      -disableAutomaticPackageResolution \
      -skipPackageUpdates \
      build
    claims+=("iOS Release build and Quality Runtime isolation")
    ;;
  *)
    echo "status=BLOCKED"
    echo "reason=unsupported_lane:$lane"
    exit 2
    ;;
esac
