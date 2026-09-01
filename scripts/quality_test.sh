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
results_root="${QUALITY_RESULTS_ROOT:-$repo_root/build/quality-results}"
result_file="${QUALITY_RESULT_FILE:-$results_root/apple-$lane-summary.json}"
runner_status_file="$results_root/apple-$lane-runner-status.txt"
runner_issue_file="$results_root/apple-$lane-runner-issues.txt"
mkdir -p "$results_root" "$(dirname "$result_file")"
rm -f "$runner_status_file"
rm -f "$runner_issue_file"
export QUALITY_RUNNER_ISSUE_FILE="$runner_issue_file"

claims=()
selected_claims=()
macos_system_notification_completed=0
macos_system_notification_not_run_claim="macOS real denied-permission recovery plus Notification Center delivery, click route, accurate canonical persistence, and relaunch evidence"
not_run=(
  "physical APNs network delivery, permission denial, physical-device notification-action/process-death parity, and other system-surface evidence"
  "physical VoiceOver task-completion evidence"
)
if [[ "$lane" != "macos-update-install" && "$lane" != "release" ]]; then
  not_run+=("macOS real Sparkle signed download, sandbox install, bundle replacement, and relaunch evidence")
fi
if [[ "$lane" != "macos-system-notification" && "$lane" != "release" ]]; then
  not_run+=("$macos_system_notification_not_run_claim")
fi
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
    write_result NOT_RUN FAILED "the selected Apple scope produced no acceptable executed-test evidence; no product claim was completed"
  elif [[ $status -eq 4 ]]; then
    write_result NOT_RUN FAILED "a required test-system sensitivity control did not reject the deliberately broken behavior"
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

minimum_free_bytes="${QUALITY_MIN_FREE_BYTES:-5368709120}"
# A changed-tests plan normally inherits the Simulator-sized 5 GiB reserve.  The
# one exception is the Store compatibility probe below: it is a host SwiftPM
# test, carries no UI scope, and cannot create an xcresult/Simulator artifact.
# Keep the exception deliberately closed rather than inferring it from a name or
# an empty plan; any new check or UI scope falls back to the full reserve.
if [[ -z "${QUALITY_MIN_FREE_BYTES:-}" && "$lane" == "changed-tests" && -n "${QUALITY_IMPACT_PLAN:-}" ]]; then
  if ! minimum_free_bytes="$(
    python3 - "$QUALITY_IMPACT_PLAN" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
plan = json.loads(path.read_text())
scopes = plan.get("required_ui_test_scopes", {})
checks = set(plan.get("required_checks", []))
if (
    plan.get("plan_status") == "READY"
    and isinstance(scopes, dict)
    and all(isinstance(items, list) and not items for items in scopes.values())
    and checks == {"apple-store-migration-reopen"}
):
    print(1073741824)
else:
    print(5368709120)
PY
  )"; then
    echo "status=BLOCKED"
    echo "reason=invalid_apple_impact_plan_for_disk_preflight"
    exit 2
  fi
fi

if ! python3 "$repo_root/scripts/quality_disk_preflight.py" \
  --path "$results_root" \
  --minimum-free-bytes "$minimum_free_bytes"; then
  exit 2
fi

run_impact_contracts() {
  local plan_path="${QUALITY_IMPACT_PLAN:-}"
  local check
  local checks_output
  local scope_lines
  local scope_platform
  local scope_profile
  local scope_list
  local scope_expected_count
  if [[ -n "$plan_path" ]]; then
    if ! scope_lines="$(
      python3 - "$plan_path" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
if not path.is_file():
    raise SystemExit(f"impact plan is not a regular file: {path}")
plan = json.loads(path.read_text())
if plan.get("plan_status") == "BLOCKED" or plan.get("selection_blockers"):
    raise SystemExit("impact plan contains unresolved selection blockers")
scope_payload = plan.get("required_ui_test_scopes", {})
if not isinstance(scope_payload, dict):
    raise SystemExit("required_ui_test_scopes must be an object")
profile_payload = plan.get("required_ui_test_profile_scopes", {})
if not isinstance(profile_payload, dict):
    raise SystemExit("required_ui_test_profile_scopes must be an object")
prefixes = {
    "ios": "PushGo-iOSUITests/",
    "macos": "PushGo-macOSUITests/",
    "watchos": "PushGo-watchOSUITests/",
}
allowed_profiles = {
    "ios": {"default", "accessibility"},
    "macos": {"default", "system"},
    "watchos": {"default"},
}
if set(scope_payload) - set(prefixes) or set(profile_payload) - set(prefixes):
    raise SystemExit("UI test scope plan contains an unsupported platform")
impacts = plan.get("ui_test_impacts", {})
if impacts and not isinstance(impacts, dict):
    raise SystemExit("ui_test_impacts must be an object")
for platform, scopes in sorted(scope_payload.items()):
    if not isinstance(scopes, list) or any(
        not isinstance(scope, str)
        or not scope.startswith(prefixes[platform])
        or scope.count("/") != 2
        or any(character.isspace() for character in scope)
        or "," in scope
        for scope in scopes
    ):
        raise SystemExit(f"invalid {platform} UI test scopes")
    if not scopes and profile_payload.get(platform):
        raise SystemExit(f"{platform} execution profiles exist without selected scopes")
    if scopes:
        profiles = profile_payload.get(platform, {})
        if not isinstance(profiles, dict) or set(profiles) - allowed_profiles[platform]:
            raise SystemExit(f"invalid {platform} UI test execution profiles")
        flattened = []
        for profile, profile_scopes in sorted(profiles.items()):
            if not isinstance(profile_scopes, list) or any(
                scope not in scopes for scope in profile_scopes
            ):
                raise SystemExit(f"invalid {platform} {profile} profile scopes")
            flattened.extend(profile_scopes)
        if len(flattened) != len(set(flattened)) or set(flattened) != set(scopes):
            raise SystemExit(f"{platform} profile scopes do not partition selected scopes")
        platform_impacts = [
            impact
            for impact in impacts.values()
            if isinstance(impact, dict) and impact.get("platform") == platform
        ]
        expected_counts = [impact.get("expected_test_count") for impact in platform_impacts]
        counts_are_valid = all(
            isinstance(count, int) and not isinstance(count, bool) and count > 0
            for count in expected_counts
        )
        if not platform_impacts or not counts_are_valid or sum(expected_counts) != len(scopes):
            raise SystemExit(f"invalid {platform} expected UI test count")
        for profile, profile_scopes in sorted(profiles.items()):
            if profile_scopes:
                print(f"{platform}\t{profile}\t{','.join(profile_scopes)}\t{len(profile_scopes)}")
PY
    )"; then
      echo "status=BLOCKED"
      echo "reason=invalid_apple_impact_ui_test_scopes"
      exit 2
    fi
    while IFS=$'\t' read -r scope_platform scope_profile scope_list scope_expected_count; do
      [[ -n "$scope_platform" && -n "$scope_profile" && -n "$scope_list" ]] || continue
      case "$scope_platform" in
        ios)
          selected_claims+=("impact-selected changed iOS UI tests ($scope_profile): $scope_list")
          if [[ "$scope_profile" == "accessibility" ]]; then
            QUALITY_EXPECTED_TEST_COUNT="$scope_expected_count" \
              run_accessibility_localization
          elif [[ "$scope_profile" == "default" ]]; then
            TEST_SCOPES="$scope_list" \
              QUALITY_EXPECTED_TEST_COUNT="$scope_expected_count" \
              MAX_RETRIES=0 \
              QUALITY_RUNNER_STATUS_FILE="$runner_status_file" "$repo_root/scripts/run_ios_ui_tests.sh"
          else
            echo "status=BLOCKED"
            echo "reason=unsupported_ios_impact_ui_profile:$scope_profile"
            exit 2
          fi
          claims+=("impact-selected changed iOS UI tests ($scope_profile): $scope_list")
          ;;
        macos)
          selected_claims+=("impact-selected changed macOS UI tests ($scope_profile): $scope_list")
          if [[ "$scope_profile" == "system" ]]; then
            local -a remaining_not_run=()
            local deferred_claim
            for deferred_claim in "${not_run[@]}"; do
              [[ "$deferred_claim" == "$macos_system_notification_not_run_claim" ]] \
                || remaining_not_run+=("$deferred_claim")
            done
            not_run=("${remaining_not_run[@]}")
            TEST_SCOPES="$scope_list" \
              QUALITY_EXPECTED_TEST_COUNT="$scope_expected_count" \
              MACOS_SCOPE_SET="system" \
              MAX_RETRIES=0 \
              QUALITY_RUNNER_STATUS_FILE="$runner_status_file" "$repo_root/scripts/run_macos_ui_tests.sh"
            macos_system_notification_completed=1
          elif [[ "$scope_profile" == "default" ]]; then
            MACOS_SCOPE_SET="default" \
              TEST_SCOPES="$scope_list" \
              QUALITY_EXPECTED_TEST_COUNT="$scope_expected_count" \
              MAX_RETRIES=0 \
              QUALITY_RUNNER_STATUS_FILE="$runner_status_file" "$repo_root/scripts/run_macos_ui_tests.sh"
          else
            echo "status=BLOCKED"
            echo "reason=unsupported_macos_impact_ui_profile:$scope_profile"
            exit 2
          fi
          claims+=("impact-selected changed macOS UI tests ($scope_profile): $scope_list")
          ;;
        watchos)
          [[ "$scope_profile" == "default" ]] || {
            echo "status=BLOCKED"
            echo "reason=unsupported_watchos_impact_ui_profile:$scope_profile"
            exit 2
          }
          selected_claims+=("impact-selected changed watchOS UI tests ($scope_profile): $scope_list")
          TEST_SCOPES="$scope_list" \
            QUALITY_EXPECTED_TEST_COUNT="$scope_expected_count" \
            QUALITY_RUNNER_STATUS_FILE="$runner_status_file" "$repo_root/scripts/run_watchos_ui_tests.sh"
          claims+=("impact-selected changed watchOS UI tests ($scope_profile): $scope_list")
          ;;
        *)
          echo "status=BLOCKED"
          echo "reason=unsupported_apple_impact_ui_platform:$scope_platform"
          exit 2
          ;;
      esac
    done <<< "$scope_lines"
  fi
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
      apple-preparation-contract)
        run_preparation_contract
        ;;
      apple-store-migration-reopen)
        selected_claims+=("old Store migration preserves a pending user action's identity, state, deadline, and Undo semantics through migration and reopen")
        swift test --package-path "$repo_root" --filter currentV24StorePreservesPendingDeletionThroughV25AndReopen
        claims+=("old Store migration preserves a pending user action's identity, state, deadline, and Undo semantics through migration and reopen")
        ;;
      apple-ios-message-unavailable-route)
        selected_claims+=("iOS stale Message route returns to a usable declared fallback")
        TEST_SCOPES="PushGo-iOSUITests/PushGo_iOSUITests/testQualityMessageDeleteWithoutUndoPermanentlyRemovesOnlyTargetAcrossRelaunch" \
          MAX_RETRIES=0 \
          QUALITY_RUNNER_STATUS_FILE="$runner_status_file" "$repo_root/scripts/run_ios_ui_tests.sh"
        claims+=("iOS stale Message route returns to a usable declared fallback")
        ;;
      apple-macos-message-unavailable-route)
        selected_claims+=("macOS stale Message route returns to a usable declared fallback")
        TEST_SCOPES="PushGo-macOSUITests/PushGo_macOSUITests/testUnavailableMessageRouteReturnsToListAndKeepsMessagesUsable" \
          MAX_RETRIES=0 \
          QUALITY_RUNNER_STATUS_FILE="$runner_status_file" "$repo_root/scripts/run_macos_ui_tests.sh"
        claims+=("macOS stale Message route returns to a usable declared fallback")
        ;;
      apple-ios-message-search-recovery)
        selected_claims+=("iOS failed Message search recovers to the requested canonical detail")
        TEST_SCOPES="PushGo-iOSUITests/PushGo_iOSUITests/testQualityMessageSearchReturnsOnlyTheTargetAndOpensItsRealDetail" \
          MAX_RETRIES=0 \
          QUALITY_RUNNER_STATUS_FILE="$runner_status_file" "$repo_root/scripts/run_ios_ui_tests.sh"
        claims+=("iOS failed Message search recovers to the requested canonical detail")
        ;;
      apple-macos-message-search-recovery)
        selected_claims+=("macOS failed Message search recovers to the requested canonical detail")
        TEST_SCOPES="PushGo-macOSUITests/PushGo_macOSUITests/testMessageSearchFailureShowsOwnedRetryAndRecoversToExactDetail" \
          MAX_RETRIES=0 \
          QUALITY_RUNNER_STATUS_FILE="$runner_status_file" "$repo_root/scripts/run_macos_ui_tests.sh"
        claims+=("macOS failed Message search recovers to the requested canonical detail")
        ;;
      apple-ios-message-delete-undo)
        selected_claims+=("iOS Message deletion Undo restores the exact canonical object after relaunch")
        TEST_SCOPES="PushGo-iOSUITests/PushGo_iOSUITests/testQualityMessageDeleteUndoRestoresTheSameObjectAcrossRelaunch" \
          MAX_RETRIES=0 \
          QUALITY_RUNNER_STATUS_FILE="$runner_status_file" "$repo_root/scripts/run_ios_ui_tests.sh"
        claims+=("iOS Message deletion Undo restores the exact canonical object after relaunch")
        ;;
      apple-ios-message-delete-commit)
        selected_claims+=("iOS Message deletion commits only its target and keeps control data across relaunch")
        TEST_SCOPES="PushGo-iOSUITests/PushGo_iOSUITests/testQualityMessageDeleteWithoutUndoPermanentlyRemovesOnlyTargetAcrossRelaunch" \
          MAX_RETRIES=0 \
          QUALITY_RUNNER_STATUS_FILE="$runner_status_file" "$repo_root/scripts/run_ios_ui_tests.sh"
        claims+=("iOS Message deletion commits only its target and keeps control data across relaunch")
        ;;
      apple-macos-message-delete-lifecycle)
        selected_claims+=("macOS Message deletion Undo and deadline commit preserve canonical data across relaunch")
        TEST_SCOPES="PushGo-macOSUITests/PushGo_macOSUITests/testMessageDeletionRestoresThenCommitsAccurateCanonicalStateAcrossRelaunch" \
          MAX_RETRIES=0 \
          QUALITY_RUNNER_STATUS_FILE="$runner_status_file" "$repo_root/scripts/run_macos_ui_tests.sh"
        claims+=("macOS Message deletion Undo and deadline commit preserve canonical data across relaunch")
        ;;
      apple-ios-channel-positive)
        selected_claims+=("iOS impact-selected Channel positive lifecycle")
        TEST_SCOPES="PushGo-iOSUITests/PushGo_iOSUITests/testChannelCreateRenameAndBothUnsubscribeOutcomesPersist" \
          MAX_RETRIES=0 \
          QUALITY_RUNNER_STATUS_FILE="$runner_status_file" "$repo_root/scripts/run_ios_ui_tests.sh"
        claims+=("iOS impact-selected Channel positive lifecycle")
        ;;
      apple-ios-channel-sheet-error-owner)
        selected_claims+=("iOS impact-selected Channel Sheet error stays with its failed action")
        TEST_SCOPES="PushGo-iOSUITests/PushGo_iOSUITests/testChannelRemoteRejectionStaysInSheetAndRetryPersists" \
          MAX_RETRIES=0 \
          QUALITY_RUNNER_STATUS_FILE="$runner_status_file" "$repo_root/scripts/run_ios_ui_tests.sh"
        claims+=("iOS Channel rejection stays in its Sheet and does not replay on the host")
        ;;
      apple-macos-channel-positive)
        selected_claims+=("macOS impact-selected Channel positive lifecycle")
        TEST_SCOPES="PushGo-macOSUITests/PushGo_macOSUITests/testUnreadBadgeAndChannelLifecyclePersistThroughRealUserActions" \
          MAX_RETRIES=0 \
          QUALITY_RUNNER_STATUS_FILE="$runner_status_file" "$repo_root/scripts/run_macos_ui_tests.sh"
        claims+=("macOS impact-selected Channel positive lifecycle")
        ;;
      apple-ios-settings-positive-extension)
        selected_claims+=("iOS impact-selected Settings positive extension")
        TEST_SCOPES="PushGo-iOSUITests/PushGo_iOSUITests/testSettingsPageVisibilityUsesRealControlsAndPersistsAcrossRelaunch,PushGo-iOSUITests/PushGo_iOSUITests/testSettingsServerUsesRealControlsAndScopesDataAfterRelaunch,PushGo-iOSUITests/PushGo_iOSUITests/testSettingsGatewaySyncFailureReportsCommittedGatewayAndPendingRecovery,PushGo-iOSUITests/PushGo_iOSUITests/testEncryptedMessageRecoversAfterConfiguringKeyAndSurvivesRelaunch" \
          MAX_RETRIES=0 \
          QUALITY_RUNNER_STATUS_FILE="$runner_status_file" "$repo_root/scripts/run_ios_ui_tests.sh"
        claims+=("iOS impact-selected Settings positive extension")
        ;;
      apple-macos-settings-positive)
        selected_claims+=("macOS impact-selected Settings purpose journeys")
        TEST_SCOPES="PushGo-macOSUITests/PushGo_macOSUITests/testSettingsPageVisibilityUsesRealControlsAndPersistsAcrossRelaunch,PushGo-macOSUITests/PushGo_macOSUITests/testGatewayCandidateMustRegisterBeforeCommitAndPersistsAfterRelaunch,PushGo-macOSUITests/PushGo_macOSUITests/testGatewaySyncFailureReportsCommittedGatewayAndPendingRecovery,PushGo-macOSUITests/PushGo_macOSUITests/testSettingsDecryptionRejectsInvalidKeyPersistsAndClearsValidKey" \
          MAX_RETRIES=0 \
          QUALITY_RUNNER_STATUS_FILE="$runner_status_file" "$repo_root/scripts/run_macos_ui_tests.sh"
        claims+=("macOS impact-selected Settings purpose journeys")
        ;;
      apple-ios-shared-form-accessibility)
        selected_claims+=("iOS impact-selected shared-form large-text purpose journey")
        QUALITY_CONTENT_SIZE="accessibility-extra-extra-extra-large" \
          TEST_SCOPES="PushGo-iOSUITests/PushGo_iOSUITests/testSimplifiedChineseAtAccessibility5CompletesMessageDetailAndChannelCreation" \
          MAX_RETRIES=0 \
          QUALITY_RUNNER_STATUS_FILE="$runner_status_file" "$repo_root/scripts/run_ios_ui_tests.sh"
        claims+=("iOS impact-selected shared-form large-text purpose journey")
        ;;
      apple-macos-shared-form-purpose)
        selected_claims+=("macOS impact-selected shared-form positive and inline-error owner journeys")
        TEST_SCOPES="PushGo-macOSUITests/PushGo_macOSUITests/testSettingsPageVisibilityUsesRealControlsAndPersistsAcrossRelaunch,PushGo-macOSUITests/PushGo_macOSUITests/testInvalidServerAddressShowsInlineFeedbackInsteadOfToast" \
          MAX_RETRIES=0 \
          QUALITY_RUNNER_STATUS_FILE="$runner_status_file" "$repo_root/scripts/run_macos_ui_tests.sh"
        claims+=("macOS impact-selected shared-form positive and inline-error owner journeys")
        ;;
      apple-macos-shared-image-preview-positive)
        selected_claims+=("macOS impact-selected image preview and native share journey")
        TEST_SCOPES="PushGo-macOSUITests/PushGo_macOSUITests/testQualityStandardMessagesShowAccurateContentAndSurviveRelaunch" \
          MAX_RETRIES=0 \
          QUALITY_RUNNER_STATUS_FILE="$runner_status_file" "$repo_root/scripts/run_macos_ui_tests.sh"
        claims+=("macOS impact-selected image preview and native share journey")
        ;;
      apple-macos-system-notification)
        run_macos_system_notification
        ;;
      *)
        echo "status=BLOCKED"
        echo "reason=unsupported_apple_impact_check:$check"
        exit 2
        ;;
    esac
  done <<< "$checks_output"
}

# PR spends device minutes on one broad positive representative per user-purpose
# family. Failure injection, deadline behavior, corruption, and compensation stay
# in Nightly/Release or run focused when their owning production code changes.
pr_ui_scopes="PushGo-iOSUITests/PushGo_iOSUITests/testQualityPrimaryNavigationUsesRealControlsAndReachesEachProductScreen,PushGo-iOSUITests/PushGo_iOSUITests/testQualityStandardMessagesShowAccurateContentAndSurviveRelaunch,PushGo-iOSUITests/PushGo_iOSUITests/testQualityMessageWorkflowLoadsSecondPageAndPersistsReadActions,PushGo-iOSUITests/PushGo_iOSUITests/testSettingsServerUsesRealControlsAndScopesDataAfterRelaunch"
macos_pr_ui_scope="PushGo-macOSUITests/PushGo_macOSUITests/testSidebarNavigationCoversPrimaryScreens"
extended_positive_ui_scopes="PushGo-iOSUITests/PushGo_iOSUITests/testHistoryCleanupRemovesOnlyOldMessagesAndPersistsAcrossRelaunch,PushGo-iOSUITests/PushGo_iOSUITests/testMarkdownFixtureRendersMajorStructuresInTheRealDetail,PushGo-iOSUITests/PushGo_iOSUITests/testMessageChannelTagCombinedUngroupedFiltersAndScopedReadPersist,PushGo-iOSUITests/PushGo_iOSUITests/testEventClosePersistsAndOngoingFilterReflectsRealProjection,PushGo-iOSUITests/PushGo_iOSUITests/testThingLifecycleFiltersRelationsAndUnavailableTargetFallback,PushGo-iOSUITests/PushGo_iOSUITests/testChannelCreateRenameAndBothUnsubscribeOutcomesPersist,PushGo-iOSUITests/PushGo_iOSUITests/testSettingsPageVisibilityUsesRealControlsAndPersistsAcrossRelaunch,PushGo-iOSUITests/PushGo_iOSUITests/testEncryptedMessageRecoversAfterConfiguringKeyAndSurvivesRelaunch"
positive_ui_scopes="$pr_ui_scopes,$extended_positive_ui_scopes"
nightly_negative_ui_scopes="PushGo-iOSUITests/PushGo_iOSUITests/testFatalStoreInitializationStopsReadWriteAndRecoversAfterRelaunch,PushGo-iOSUITests/PushGo_iOSUITests/testQualityMessageSearchReturnsOnlyTheTargetAndOpensItsRealDetail,PushGo-iOSUITests/PushGo_iOSUITests/testQualityMessageDeleteUndoRestoresTheSameObjectAcrossRelaunch,PushGo-iOSUITests/PushGo_iOSUITests/testQualityMessageDeleteWithoutUndoPermanentlyRemovesOnlyTargetAcrossRelaunch,PushGo-iOSUITests/PushGo_iOSUITests/testSlowMessageLoadBecomesVisibleBeforeDataCompletes,PushGo-iOSUITests/PushGo_iOSUITests/testSlowMessageRefreshKeepsAccurateContentVisibleUntilCompletion,PushGo-iOSUITests/PushGo_iOSUITests/testMessageRefreshFailureKeepsSnapshotAndRetryRecoversPersistedResult,PushGo-iOSUITests/PushGo_iOSUITests/testMessageLoadFailureShowsRetryAndRecoversToRealDataState,PushGo-iOSUITests/PushGo_iOSUITests/testEventCloseFailureKeepsAccurateDetailBlocksDuplicateAndRetryPersists,PushGo-iOSUITests/PushGo_iOSUITests/testChannelRemoteRejectionStaysInSheetAndRetryPersists,PushGo-iOSUITests/PushGo_iOSUITests/testChannelCreateLocalFailureCompensatesRemoteBeforeRetry,PushGo-iOSUITests/PushGo_iOSUITests/testGatewayLocalCommitFailureRollsBackBeforeRetryCommits,PushGo-iOSUITests/PushGo_iOSUITests/testSettingsServerRejectsInvalidAndUnregisteredCandidatesWithoutLeakingSheetError,PushGo-iOSUITests/PushGo_iOSUITests/testSettingsGatewaySyncFailureReportsCommittedGatewayAndPendingRecovery,PushGo-iOSUITests/PushGo_iOSUITests/testSettingsDecryptionRejectsInvalidKeyPersistsAndClearsValidKey,PushGo-iOSUITests/PushGo_iOSUITests/testDecryptionProtectedStoreFailureDoesNotConfigureBeforeRetry,PushGo-iOSUITests/PushGo_iOSUITests/testCorruptEncryptedMessageFailsSafelyAndSurvivesRelaunch"
accessibility_ui_scope="PushGo-iOSUITests/PushGo_iOSUITests/testSimplifiedChineseAtAccessibility5CompletesMessageDetailAndChannelCreation"
nightly_ui_scopes="$positive_ui_scopes,$nightly_negative_ui_scopes"
watch_ui_scopes="PushGo-watchOSUITests/PushGo_watchOSUITests/testCoreWatchJourneyShowsAccurateObjectsDeletesOneAndPersistsAfterRelaunch,PushGo-watchOSUITests/PushGo_watchOSUITests/testLegacyWatchStoreMigratesAccurateMessageAndKeepsNewDataAcrossRelaunch,PushGo-watchOSUITests/PushGo_watchOSUITests/testInvalidHermeticScenarioFailsReadinessExplicitly,PushGo-watchOSUITests/PushGo_watchOSUITests/testMessageReadFailureStaysOwnedByMessagesWhileOtherDomainsRemainUsable"
performance_ui_scope="PushGo-iOSUITests/PushGo_iOSUITests/testPreparedLargeMessageStoreColdLaunchReachesAccurateContent"
macos_performance_ui_scope="PushGo-macOSUITests/PushGo_macOSUITests/testPreparedLargeMessageStoreColdLaunchReachesAccurateContent"

run_core() {
  selected_claims+=("Apple Core/Store/integration suite and localization completeness")
  "$repo_root/scripts/quality_doctor.sh"
  python3 "$repo_root/scripts/verify_apple_localizations.py"
  swift test --package-path "$repo_root"
  claims+=("Apple Core/Store/integration suite and localization completeness")
}

run_preparation_contract() {
  local ios_scopes="PushGo-iOSUITests/PushGo_iOSUITests/testInvalidQualitySessionStopsBeforeBusinessUIWithinTenSeconds,PushGo-iOSUITests/PushGo_iOSUITests/testQualitySessionUsesAppOwnedStoreAndReachesFunctionalEmptyState"
  local macos_scopes="PushGo-macOSUITests/PushGo_macOSUITests/testInvalidQualitySessionStopsBeforeBusinessUIWithinTenSeconds,PushGo-macOSUITests/PushGo_macOSUITests/testQualitySessionUsesAppOwnedStoreAndReachesFunctionalEmptyState"
  selected_claims+=("Apple App-owned preparation rejects invalid sessions within 10 seconds and recovers to accurate functional empty state")
  TEST_SCOPES="$ios_scopes" \
    MAX_RETRIES=0 \
    QUALITY_RUNNER_STATUS_FILE="$runner_status_file" "$repo_root/scripts/run_ios_ui_tests.sh"
  TEST_SCOPES="$macos_scopes" \
    MAX_RETRIES=0 \
    QUALITY_RUNNER_STATUS_FILE="$runner_status_file" "$repo_root/scripts/run_macos_ui_tests.sh"
  claims+=("Apple App-owned preparation rejects invalid sessions within 10 seconds and recovers to accurate functional empty state")
}

run_performance() {
  local performance_log="$results_root/apple-performance.log"
  local ios_performance_runner_log="$results_root/apple-ios-performance-runner.log"
  local ios_performance_result_bundle
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
    QUALITY_RUNNER_STATUS_FILE="$runner_status_file" "$repo_root/scripts/run_ios_ui_tests.sh" \
    | tee "$ios_performance_runner_log"
  ios_performance_result_bundle="$(sed -n 's/^result_bundle=//p' "$ios_performance_runner_log" | tail -n 1)"
  [[ -n "$ios_performance_result_bundle" ]] || {
    echo "status=FAILED_TEST_SYSTEM"
    echo "reason=ios_performance_result_bundle_missing"
    exit 3
  }
  python3 "$repo_root/scripts/extract_ios_performance_evidence.py" \
    --result-bundle "$ios_performance_result_bundle" \
    --output "$results_root/apple-ios-performance-evidence.json"
  claims+=("iOS prepared 1k Store cold-launch-to-accurate-content metrics and purpose oracle")
  selected_claims+=("macOS prepared 1k Store cold-launch-to-accurate-content local metrics and purpose oracle")
  TEST_SCOPES="$macos_performance_ui_scope" \
    MAX_RETRIES=0 \
    QUALITY_RUNNER_STATUS_FILE="$runner_status_file" "$repo_root/scripts/run_macos_ui_tests.sh"
  claims+=("macOS prepared 1k Store cold-launch-to-accurate-content local metrics and purpose oracle")
  QUALITY_REUSE_BUILT_TESTS=1 \
    "$repo_root/scripts/run_macos_performance_negative_control.sh"
  QUALITY_REUSE_BUILT_TESTS=1 \
    "$repo_root/scripts/run_ios_performance_negative_control.sh"
  QUALITY_REUSE_BUILT_TESTS=1 \
    "$repo_root/scripts/run_ios_data_field_negative_control.sh"
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
  selected_claims+=("watchOS App-owned Messages/Event/Thing, legacy Store migration, and explicit readiness failure journeys")
  local watch_scope
  local -a watch_scope_list
  IFS=',' read -r -a watch_scope_list <<< "$watch_ui_scopes"
  for watch_scope in "${watch_scope_list[@]}"; do
    [[ -n "$watch_scope" ]] || continue
    TEST_SCOPE="$watch_scope" \
      QUALITY_RUNNER_STATUS_FILE="$runner_status_file" "$repo_root/scripts/run_watchos_ui_tests.sh"
  done
  claims+=("watchOS App-owned Messages/Event/Thing, legacy Store migration, and explicit readiness failure journeys")
}

run_macos_ui() {
  local scope_set="${1:-positive}"
  local requested_scopes="${TEST_SCOPES:-}"
  local claim="macOS ${scope_set} App-owned user-purpose journeys"
  if [[ -n "$requested_scopes" ]]; then
    claim="macOS explicitly selected UI journeys: $requested_scopes"
  fi
  selected_claims+=("$claim")
  MACOS_SCOPE_SET="$scope_set" \
    MAX_RETRIES=0 \
    QUALITY_RUNNER_STATUS_FILE="$runner_status_file" "$repo_root/scripts/run_macos_ui_tests.sh"
  claims+=("$claim")
}

run_macos_update_install() {
  selected_claims+=("macOS real Sparkle signed update install and relaunch journey")
  "$repo_root/scripts/run_macos_update_install_test.sh"
  claims+=("macOS real Sparkle signed update install and relaunch journey")
}

run_macos_system_notification() {
  [[ $macos_system_notification_completed -eq 0 ]] || return 0
  local -a remaining_not_run=()
  local deferred_claim
  for deferred_claim in "${not_run[@]}"; do
    [[ "$deferred_claim" == "$macos_system_notification_not_run_claim" ]] \
      || remaining_not_run+=("$deferred_claim")
  done
  not_run=("${remaining_not_run[@]}")
  selected_claims+=("macOS real denied-permission recovery plus Notification Center delivery, click route, accurate canonical persistence, and relaunch journey")
  MACOS_SCOPE_SET=system \
    MAX_RETRIES=0 \
    QUALITY_RUNNER_STATUS_FILE="$runner_status_file" "$repo_root/scripts/run_macos_ui_tests.sh"
  claims+=("macOS real denied-permission recovery plus Notification Center delivery, click route, accurate canonical persistence, and relaunch journey")
  macos_system_notification_completed=1
}

run_ios_positive() {
  selected_claims+=("iOS complete positive App-owned journeys before fault injection")
  TEST_SCOPES="$positive_ui_scopes" \
    MAX_RETRIES=0 \
    QUALITY_RUNNER_STATUS_FILE="$runner_status_file" "$repo_root/scripts/run_ios_ui_tests.sh"
  claims+=("iOS complete positive App-owned journeys before fault injection")
}

run_ios_positive_then_risk() {
  local requested_scopes="${TEST_SCOPES:-${TEST_SCOPE:-}}"
  if [[ -n "$requested_scopes" ]]; then
    selected_claims+=("iOS explicitly selected UI journeys: $requested_scopes")
    TEST_SCOPES="$requested_scopes" \
      MAX_RETRIES="${MAX_RETRIES:-0}" \
      QUALITY_RUNNER_STATUS_FILE="$runner_status_file" "$repo_root/scripts/run_ios_ui_tests.sh"
    claims+=("iOS explicitly selected UI journeys: $requested_scopes")
    return
  fi

  run_ios_positive

  selected_claims+=("iOS impact-worthy failure, corruption, and compensation journeys")
  TEST_SCOPES="$nightly_negative_ui_scopes" \
    MAX_RETRIES=0 \
    QUALITY_RUNNER_STATUS_FILE="$runner_status_file" "$repo_root/scripts/run_ios_ui_tests.sh"
  claims+=("iOS impact-worthy failure, corruption, and compensation journeys")
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

run_impact_contracts

case "$lane" in
  changed-tests)
    if (( ${#claims[@]} == 0 )); then
      echo "status=BLOCKED"
      echo "reason=changed_tests_lane_requires_resolved_impact_scopes"
      exit 2
    fi
    ;;
  preparation)
    run_preparation_contract
    ;;
  macos-update-install)
    run_macos_update_install
    ;;
  macos-system-notification)
    run_macos_system_notification
    ;;
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
    run_macos_ui positive
    ;;
  ios-positive)
    run_ios_positive
    ;;
  pr)
    run_core
    selected_claims+=("iOS broad positive App-owned journeys across launch, Messages, navigation, Event, Thing, Channel, and Settings")
    TEST_SCOPES="${TEST_SCOPES:-$pr_ui_scopes}" \
      MAX_RETRIES="${MAX_RETRIES:-0}" \
      QUALITY_RUNNER_STATUS_FILE="$runner_status_file" "$repo_root/scripts/run_ios_ui_tests.sh"
    claims+=("iOS broad positive App-owned journeys across launch, Messages, navigation, Event, Thing, Channel, and Settings")
    TEST_SCOPES="$macos_pr_ui_scope" run_macos_ui positive
    ;;
  nightly)
    run_core
    run_ios_positive_then_risk
    run_system_notification_journey
    run_watch_ui
    run_accessibility_localization
    run_macos_ui full
    ;;
  release)
    run_core
    run_ios_positive_then_risk
    run_system_notification_journey
    run_watch_ui
    run_accessibility_localization
    run_macos_system_notification
    run_macos_ui full
    run_macos_update_install
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
