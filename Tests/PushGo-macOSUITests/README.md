# PushGo macOS UI quality suite

## Current executable scope

The target now exposes twelve XCTest-discoverable, App-owned journeys:

- App-owned empty-state launch and functional message-list readiness;
- accurate standard message row/detail data and process-relaunch persistence;
- a user-visible slow-load warning before delayed completion;
- visible initial-load failure and recovery through the real Retry control;
- slow refresh feedback while the last accurate snapshot remains visible;
- refresh failure ownership, retry, accurate new detail, and relaunch persistence;
- accurate Event row/detail data, confirmed close through the production-shaped delivery path, closed-state persistence, and no repeated close action;
- accurate Thing identity/summary, real Event/Message/Update relation details, working Sheet return, and relaunch persistence;
- real Sidebar navigation across primary destinations;
- real Settings entry to the decryption overlay;
- inline invalid-server feedback through real controls;
- close/status-item/reopen window lifecycle with one functional window.

The 18 host-path/command/state methods are named `legacyDiagnostic...` and no longer use XCTest's `test...` discovery convention. Their green results never counted as product coverage. The twelve current journeys use the App-owned quality session and real accessibility UI; they do not read the App database or state files from the host test process. Event slow/error/duplicate-close, Thing filter/deep-link/delete, page-visibility persistence, Gateway commit, notification action, and performance journeys remain explicit gaps until replaced by App-owned user-purpose tests.

## Run

Use the zero-retry repository runner. It first proves that the interactive console is unlocked, then holds a scoped `caffeinate` assertion so a long lane cannot idle back to the login screen. XCTest closes the exact macOS system `Problem Reporter` application in every journey's setup and teardown; the outer runner also closes the exact process before/after the batch and on interruption/exit. It terminates only stale test-built PushGo/Runner processes at the batch boundary, preventing an interrupted prior run's background App from blocking activation. Therefore an App crash cannot leave its system dialog above the next journey without paying the instability cost of relaunching the UI-test Runner for every method. A crashed journey remains `FAILED`; closing the system dialog is test-environment cleanup, never a retry or a route to green. A locked console or a dialog that cannot be closed is explicitly `BLOCKED` instead of becoming a misleading product failure:

```bash
./scripts/run_macos_ui_tests.sh
```

Set comma-separated `TEST_SCOPES` for a focused run. The runner requires a normal local development signature. A local automation-authorization or pre-execution runner failure is test-system `BLOCKED`; an executed oracle failure is product `FAILED`; neither is retried into green. Core semantic/storage checks remain in `PushGoAppleCoreTests`, but they do not replace the missing physical macOS UI journeys.
