#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lane="${1:-pr}"

core_ui_scopes="PushGo-iOSUITests/PushGo_iOSUITests/testQualitySessionUsesAppOwnedStoreAndReachesFunctionalEmptyState,PushGo-iOSUITests/PushGo_iOSUITests/testQualityStandardMessagesShowAccurateContentAndSurviveRelaunch,PushGo-iOSUITests/PushGo_iOSUITests/testSlowMessageLoadBecomesVisibleBeforeDataCompletes,PushGo-iOSUITests/PushGo_iOSUITests/testMessageLoadFailureShowsRetryAndRecoversToRealDataState"
nightly_ui_scopes="$core_ui_scopes,PushGo-iOSUITests/PushGo_iOSUITests/testNavSwitchTabMatrixCoversPrimaryScreens,PushGo-iOSUITests/PushGo_iOSUITests/testImportedEventFixtureCanOpenEventDetail,PushGo-iOSUITests/PushGo_iOSUITests/testImportedThingFixtureCanOpenThingDetail,PushGo-iOSUITests/PushGo_iOSUITests/testInvalidServerAddressShowsInlineFeedbackInsteadOfToast,PushGo-iOSUITests/PushGo_iOSUITests/testSubmittingPopulatedSearchResultsKeepsAppRunning"

run_core() {
  "$repo_root/scripts/quality_doctor.sh"
  swift test --package-path "$repo_root"
}

case "$lane" in
  focused)
    [[ -n "${TEST_SCOPES:-${TEST_SCOPE:-}}" ]] || {
      echo "status=BLOCKED"
      echo "reason=focused_lane_requires_TEST_SCOPES"
      exit 2
    }
    "$repo_root/scripts/run_ios_ui_tests.sh"
    ;;
  pr)
    run_core
    TEST_SCOPES="${TEST_SCOPES:-$core_ui_scopes}" \
      MAX_RETRIES="${MAX_RETRIES:-1}" \
      "$repo_root/scripts/run_ios_ui_tests.sh"
    ;;
  nightly)
    run_core
    TEST_SCOPES="${TEST_SCOPES:-$nightly_ui_scopes}" \
      MAX_RETRIES="${MAX_RETRIES:-1}" \
      "$repo_root/scripts/run_ios_ui_tests.sh"
    ;;
  release)
    run_core
    TEST_SCOPES="${TEST_SCOPES:-}" "$repo_root/scripts/run_ios_ui_tests.sh"
    xcodebuild \
      -project "$repo_root/pushgo.xcodeproj" \
      -scheme PushGo-iOS \
      -configuration Release \
      -destination 'generic/platform=iOS Simulator' \
      -onlyUsePackageVersionsFromResolvedFile \
      -disableAutomaticPackageResolution \
      -skipPackageUpdates \
      build
    ;;
  *)
    echo "status=BLOCKED"
    echo "reason=unsupported_lane:$lane"
    exit 2
    ;;
esac
