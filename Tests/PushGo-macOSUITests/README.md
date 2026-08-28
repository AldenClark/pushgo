# PushGo macOS UI quality suite

## Current executable scope

The target now exposes five XCTest-discoverable, App-owned journeys:

- App-owned empty-state launch and functional message-list readiness;
- real Sidebar navigation across primary destinations;
- real Settings entry to the decryption overlay;
- inline invalid-server feedback through real controls;
- close/status-item/reopen window lifecycle with one functional window.

The 18 host-path/command/state methods are named `legacyDiagnostic...` and no longer use XCTest's `test...` discovery convention. Their green results never counted as product coverage. The five current journeys use the App-owned quality session and real accessibility UI; they do not read the App database or state files from the host test process. Missing macOS Event/Thing detail, page-visibility persistence, Gateway commit, notification action, and performance journeys remain explicit gaps until replaced by App-owned user-purpose tests.

## Run

Use the zero-retry repository runner. It closes stale macOS `Problem Reporter` dialogs before and after execution so a prior crash cannot cover the next UI journey:

```bash
./scripts/run_macos_ui_tests.sh
```

Set comma-separated `TEST_SCOPES` for a focused run. The runner requires a normal local development signature. A local automation-authorization or pre-execution runner failure is test-system `BLOCKED`; an executed oracle failure is product `FAILED`; neither is retried into green. Core semantic/storage checks remain in `PushGoAppleCoreTests`, but they do not replace the missing physical macOS UI journeys.
