#!/usr/bin/env bash
set -euo pipefail

if [[ "${PUSHGO_APPLE_QUALITY_SCRIPT_SNAPSHOT:-0}" != "1" ]]; then
  script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  export PUSHGO_APPLE_QUALITY_SCRIPT_SNAPSHOT=1
  export PUSHGO_APPLE_QUALITY_REPO_ROOT="$(cd "$(dirname "$script_path")/.." && pwd)"
  exec /bin/bash -s -- "$@" < "$script_path"
fi

repo_root="${PUSHGO_APPLE_QUALITY_REPO_ROOT:?missing quality script repository root}"
lane="${1:-pr}"
results_root="$repo_root/build/quality-results"
result_file="$results_root/apple-$lane-summary.json"
runner_status_file="$results_root/apple-$lane-runner-status.txt"
runner_issue_file="$results_root/apple-$lane-runner-issues.txt"
mkdir -p "$results_root"
rm -f "$runner_status_file"
rm -f "$runner_issue_file"
export QUALITY_RUNNER_ISSUE_FILE="$runner_issue_file"

claims=()
selected_claims=()
not_run=(
  "physical APNs network delivery, permission denial, physical-device notification-action/process-death parity, and other system-surface evidence"
  "physical VoiceOver task-completion evidence"
)
physical_performance_requested=0
not_run+=("physical-device frame/hitch and release trace evidence")
if [[ ( "$lane" == "performance" || "$lane" == "release" ) && -n "${IOS_PERFORMANCE_DEVICE_ID:-}" ]]; then
  physical_performance_requested=1
else
  not_run+=("physical-device launch-to-accurate-content performance evidence")
fi
if [[ "$lane" != "performance" && "$lane" != "release" ]]; then
  not_run+=("opt-in 100k Store plus 10k Watch/concurrency performance evidence")
fi

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
  for item in "${selected_claims[@]-}"; do [[ -z "$item" ]] || args+=(--selected-claim "$item"); done
  for item in "${claims[@]-}"; do [[ -z "$item" ]] || args+=(--claim "$item"); done
  for item in "${not_run[@]}"; do args+=(--not-run "$item"); done
  if [[ -f "$runner_issue_file" ]]; then
    while IFS= read -r item; do
      [[ -z "$item" ]] || args+=(--test-system-issue-id "$item")
    done < <(sort -u "$runner_issue_file")
  fi
  [[ -z "$reason" ]] || args+=(--reason "$reason")
  python3 "$repo_root/scripts/quality_result.py" "${args[@]}"
}

on_exit() {
  local status=$?
  local runner_status="PASSED"
  [[ ! -f "$runner_status_file" ]] || runner_status="$(<"$runner_status_file")"
  if [[ $status -eq 0 ]]; then
    write_result PASSED "$runner_status"
  elif [[ $status -eq 2 ]]; then
    write_result NOT_RUN BLOCKED "lane preparation was blocked before product evidence completed"
  elif [[ $status -eq 3 ]]; then
    write_result NOT_RUN FAILED "the selected Apple test scope executed zero tests; no product claim was completed"
  else
    write_result FAILED "$runner_status" "an executed product oracle failed; inspect xcresult/log for the first failure"
  fi
  printf 'quality_result=%s\n' "$result_file"
}
trap on_exit EXIT

if ! python3 "$repo_root/scripts/quality_test_system_issues.py" --check; then
  echo "status=BLOCKED"
  echo "reason=invalid_or_expired_apple_test_system_issue_registry"
  exit 2
fi

if ! python3 "$repo_root/scripts/quality_disk_preflight.py" \
  --path "$results_root" \
  --minimum-free-bytes "${QUALITY_MIN_FREE_BYTES:-5368709120}"; then
  exit 2
fi

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

# PR spends device minutes on one broad positive representative per user-purpose
# family. Failure injection, deadline behavior, corruption, and compensation stay
# in Nightly/Release or run focused when their owning production code changes.
pr_ui_scopes="PushGo-iOSUITests/PushGo_iOSUITests/testQualityStandardMessagesShowAccurateContentAndSurviveRelaunch,PushGo-iOSUITests/PushGo_iOSUITests/testMarkdownFixtureRendersMajorStructuresInTheRealDetail,PushGo-iOSUITests/PushGo_iOSUITests/testQualityMessageWorkflowLoadsSecondPageAndPersistsReadActions,PushGo-iOSUITests/PushGo_iOSUITests/testMessageChannelTagCombinedUngroupedFiltersAndScopedReadPersist,PushGo-iOSUITests/PushGo_iOSUITests/testMessageRefreshPersistsNewProviderResultAndOpensItsRealDetail,PushGo-iOSUITests/PushGo_iOSUITests/testQualityPrimaryNavigationUsesRealControlsAndReachesEachProductScreen,PushGo-iOSUITests/PushGo_iOSUITests/testEventClosePersistsAndOngoingFilterReflectsRealProjection,PushGo-iOSUITests/PushGo_iOSUITests/testImportedThingFixtureCanOpenThingDetail,PushGo-iOSUITests/PushGo_iOSUITests/testChannelCreateRenameAndBothUnsubscribeOutcomesPersist,PushGo-iOSUITests/PushGo_iOSUITests/testSettingsPageVisibilityUsesRealControlsAndPersistsAcrossRelaunch,PushGo-iOSUITests/PushGo_iOSUITests/testSettingsServerUsesRealControlsAndScopesDataAfterRelaunch,PushGo-iOSUITests/PushGo_iOSUITests/testEncryptedMessageRecoversAfterConfiguringKeyAndSurvivesRelaunch"
nightly_negative_ui_scopes="PushGo-iOSUITests/PushGo_iOSUITests/testFatalStoreInitializationStopsReadWriteAndRecoversAfterRelaunch,PushGo-iOSUITests/PushGo_iOSUITests/testQualityMessageDeleteUndoRestoresTheSameObjectAcrossRelaunch,PushGo-iOSUITests/PushGo_iOSUITests/testQualityMessageDeleteWithoutUndoPermanentlyRemovesOnlyTargetAcrossRelaunch,PushGo-iOSUITests/PushGo_iOSUITests/testSlowMessageLoadBecomesVisibleBeforeDataCompletes,PushGo-iOSUITests/PushGo_iOSUITests/testSlowMessageRefreshKeepsAccurateContentVisibleUntilCompletion,PushGo-iOSUITests/PushGo_iOSUITests/testMessageRefreshFailureKeepsSnapshotAndRetryRecoversPersistedResult,PushGo-iOSUITests/PushGo_iOSUITests/testMessageLoadFailureShowsRetryAndRecoversToRealDataState,PushGo-iOSUITests/PushGo_iOSUITests/testEventCloseFailureKeepsAccurateDetailBlocksDuplicateAndRetryPersists,PushGo-iOSUITests/PushGo_iOSUITests/testChannelRemoteRejectionStaysInSheetAndRetryPersists,PushGo-iOSUITests/PushGo_iOSUITests/testChannelCreateLocalFailureCompensatesRemoteBeforeRetry,PushGo-iOSUITests/PushGo_iOSUITests/testGatewayLocalCommitFailureRollsBackBeforeRetryCommits,PushGo-iOSUITests/PushGo_iOSUITests/testSettingsDecryptionRejectsInvalidKeyPersistsAndClearsValidKey,PushGo-iOSUITests/PushGo_iOSUITests/testDecryptionProtectedStoreFailureDoesNotConfigureBeforeRetry,PushGo-iOSUITests/PushGo_iOSUITests/testCorruptEncryptedMessageFailsSafelyAndSurvivesRelaunch"
accessibility_ui_scope="PushGo-iOSUITests/PushGo_iOSUITests/testSimplifiedChineseAtAccessibility5CompletesMessageDetailAndChannelCreation"
nightly_ui_scopes="$pr_ui_scopes,$nightly_negative_ui_scopes"
watch_ui_scopes="PushGo-watchOSUITests/PushGo_watchOSUITests/testCoreWatchJourneyShowsAccurateObjectsDeletesOneAndPersistsAfterRelaunch,PushGo-watchOSUITests/PushGo_watchOSUITests/testInvalidHermeticScenarioFailsReadinessExplicitly,PushGo-watchOSUITests/PushGo_watchOSUITests/testMessageReadFailureStaysOwnedByMessagesWhileOtherDomainsRemainUsable"
performance_ui_scope="PushGo-iOSUITests/PushGo_iOSUITests/testPreparedLargeMessageStoreColdLaunchReachesAccurateContent"

run_core() {
  selected_claims+=("Apple Core/Store/integration suite and localization completeness")
  "$repo_root/scripts/quality_doctor.sh"
  python3 "$repo_root/scripts/verify_apple_localizations.py"
  swift test --package-path "$repo_root"
  claims+=("Apple Core/Store/integration suite and localization completeness")
}

run_performance() {
  local performance_log="$results_root/apple-performance.log"
  selected_claims+=("Apple 100k Store plus 10k Watch/concurrency correctness and provisional host regression ceilings")
  selected_claims+=("iOS prepared 1k Store cold-launch-to-accurate-content metrics and purpose oracle")
  "$repo_root/scripts/quality_doctor.sh" --host-only
  PUSHGO_RUNTIME_QUALITY=1 swift test \
    --package-path "$repo_root" \
    --filter RuntimeQualityLargeScaleTests \
    2>&1 | tee "$performance_log"
  claims+=("Apple 100k Store plus 10k Watch/concurrency correctness and provisional host regression ceilings")
  TEST_SCOPES="$performance_ui_scope" \
    MAX_RETRIES=0 \
    QUALITY_RUNNER_STATUS_FILE="$runner_status_file" "$repo_root/scripts/run_ios_ui_tests.sh"
  claims+=("iOS prepared 1k Store cold-launch-to-accurate-content metrics and purpose oracle")
  if [[ $physical_performance_requested -eq 1 ]]; then
    selected_claims+=("iOS fixed physical reference-device Release launch-to-accurate-content budget")
    "$repo_root/scripts/run_ios_physical_performance.sh"
    claims+=("iOS fixed physical reference-device Release launch-to-accurate-content budget")
  fi
}

run_accessibility_localization() {
  selected_claims+=("iOS zh-Hans accessibility5 real message-detail and channel-creation journey")
  python3 "$repo_root/scripts/verify_apple_localizations.py"
  QUALITY_CONTENT_SIZE="accessibility-extra-extra-extra-large" \
    TEST_SCOPES="$accessibility_ui_scope" \
    MAX_RETRIES="${MAX_RETRIES:-0}" \
    QUALITY_RUNNER_STATUS_FILE="$runner_status_file" "$repo_root/scripts/run_ios_ui_tests.sh"
  claims+=("iOS zh-Hans accessibility5 real message-detail and channel-creation journey")
}

run_watch_ui() {
  selected_claims+=("watchOS App-owned Messages/Event/Thing journey and explicit readiness failure")
  local watch_scope
  local -a watch_scope_list
  IFS=',' read -r -a watch_scope_list <<< "$watch_ui_scopes"
  for watch_scope in "${watch_scope_list[@]}"; do
    [[ -n "$watch_scope" ]] || continue
    TEST_SCOPE="$watch_scope" \
      QUALITY_RUNNER_STATUS_FILE="$runner_status_file" "$repo_root/scripts/run_watchos_ui_tests.sh"
  done
  claims+=("watchOS App-owned Messages/Event/Thing journey and explicit readiness failure")
}

run_macos_ui() {
  selected_claims+=("macOS App-owned message empty/standard/initial-and-refresh slow/failure-retry/persistence, primary navigation, Settings feedback, and close/status-item/reopen journeys")
  MAX_RETRIES=0 \
    QUALITY_RUNNER_STATUS_FILE="$runner_status_file" "$repo_root/scripts/run_macos_ui_tests.sh"
  claims+=("macOS App-owned message empty/standard/initial-and-refresh slow/failure-retry/persistence, primary navigation, Settings feedback, and close/status-item/reopen journeys")
}

run_system_notification_journey() {
  local cold_launch_scope="PushGo-iOSUITests/PushGo_iOSSystemNotificationTests/testSystemNotificationTapColdLaunchesAccurateReadDetailAndPersists"
  local delete_action_scope="PushGo-iOSUITests/PushGo_iOSSystemNotificationTests/testSystemNotificationDeleteActionRemovesOnlyTargetAndPersists"
  local mark_read_action_scope="PushGo-iOSUITests/PushGo_iOSSystemNotificationTests/testSystemNotificationMarkReadActionPersistsAccurateReadTarget"
  selected_claims+=("iOS Simulator system notification permission/delivery/hot-and-terminated-process tap/detail/read plus direct mark-read and destructive delete/control/relaunch journeys")
  MAX_RETRIES=0 \
    QUALITY_RUNNER_STATUS_FILE="$runner_status_file" "$repo_root/scripts/run_ios_system_notification_test.sh"
  SYSTEM_NOTIFICATION_TEST_SCOPE="$cold_launch_scope" \
    PRESERVE_SYSTEM_NOTIFICATION_INSTALL=1 \
    MAX_RETRIES=0 \
    QUALITY_RUNNER_STATUS_FILE="$runner_status_file" "$repo_root/scripts/run_ios_system_notification_test.sh"
  SYSTEM_NOTIFICATION_TEST_SCOPE="$delete_action_scope" \
    PRESERVE_SYSTEM_NOTIFICATION_INSTALL=1 \
    MAX_RETRIES=0 \
    QUALITY_RUNNER_STATUS_FILE="$runner_status_file" "$repo_root/scripts/run_ios_system_notification_test.sh"
  SYSTEM_NOTIFICATION_TEST_SCOPE="$mark_read_action_scope" \
    PRESERVE_SYSTEM_NOTIFICATION_INSTALL=1 \
    MAX_RETRIES=0 \
    QUALITY_RUNNER_STATUS_FILE="$runner_status_file" "$repo_root/scripts/run_ios_system_notification_test.sh"
  claims+=("iOS Simulator system notification permission/delivery/hot-and-terminated-process tap/detail/read plus direct mark-read and destructive delete/control/relaunch journeys")
}

case "$lane" in
  system-notification)
    run_system_notification_journey
    ;;
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
  performance)
    run_performance
    ;;
  accessibility)
    run_accessibility_localization
    ;;
  macos)
    run_macos_ui
    ;;
  pr)
    run_core
    selected_claims+=("iOS broad positive App-owned journeys across launch, Messages, navigation, Event, Thing, Channel, and Settings")
    TEST_SCOPES="${TEST_SCOPES:-$pr_ui_scopes}" \
      MAX_RETRIES="${MAX_RETRIES:-0}" \
      QUALITY_RUNNER_STATUS_FILE="$runner_status_file" "$repo_root/scripts/run_ios_ui_tests.sh"
    claims+=("iOS broad positive App-owned journeys across launch, Messages, navigation, Event, Thing, Channel, and Settings")
    ;;
  nightly)
    run_core
    selected_claims+=("iOS core message journeys plus navigation/Event/Thing/Channel/Settings persistence representatives")
    TEST_SCOPES="${TEST_SCOPES:-$nightly_ui_scopes}" \
      MAX_RETRIES="${MAX_RETRIES:-0}" \
      QUALITY_RUNNER_STATUS_FILE="$runner_status_file" "$repo_root/scripts/run_ios_ui_tests.sh"
    claims+=("iOS core message journeys plus navigation/Event/Thing/Channel/Settings persistence representatives")
    run_system_notification_journey
    run_watch_ui
    run_accessibility_localization
    run_macos_ui
    ;;
  release)
    run_core
    selected_claims+=("iOS release-lane representative journeys")
    TEST_SCOPES="${TEST_SCOPES:-$nightly_ui_scopes}" \
      MAX_RETRIES="${MAX_RETRIES:-0}" \
      QUALITY_RUNNER_STATUS_FILE="$runner_status_file" "$repo_root/scripts/run_ios_ui_tests.sh"
    claims+=("iOS release-lane representative journeys")
    run_system_notification_journey
    run_watch_ui
    run_accessibility_localization
    run_macos_ui
    run_performance
    selected_claims+=("iOS/watchOS Release builds and Quality Runtime isolation")
    xcodebuild \
      -project "$repo_root/pushgo.xcodeproj" \
      -scheme PushGo-iOS \
      -configuration Release \
      -destination 'generic/platform=iOS Simulator' \
      -onlyUsePackageVersionsFromResolvedFile \
      -disableAutomaticPackageResolution \
      -skipPackageUpdates \
      build
    xcodebuild \
      -project "$repo_root/pushgo.xcodeproj" \
      -scheme PushGo-watchOS \
      -configuration Release \
      -destination 'generic/platform=watchOS Simulator' \
      -onlyUsePackageVersionsFromResolvedFile \
      -disableAutomaticPackageResolution \
      -skipPackageUpdates \
      CODE_SIGNING_ALLOWED=NO \
      build
    claims+=("iOS/watchOS Release builds and Quality Runtime isolation")
    ;;
  *)
    echo "status=BLOCKED"
    echo "reason=unsupported_lane:$lane"
    exit 2
    ;;
esac
