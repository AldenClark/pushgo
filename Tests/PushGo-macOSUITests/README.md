# PushGo macOS UI quality suite

## Current executable scope

The target now exposes twenty-five curated XCTest-discoverable, App-owned product journeys:

- App-owned empty-state launch and functional message-list readiness;
- accurate standard message row/detail data and process-relaunch persistence;
- selected Messages sidebar title remains visibly readable, non-overlapping, and navigable with a real canonical 100+ unread Store rendered as `99+`;
- message deletion through the real detail action, immediate suppression, real Undo, exact-content restoration, and process-relaunch persistence;
- deletion deadline commit that permanently removes only the target while preserving an accurate unrelated control message across relaunch;
- a user-visible slow-load warning before delayed completion;
- visible initial-load failure and recovery through the real Retry control;
- slow refresh feedback while the last accurate snapshot remains visible;
- refresh failure ownership, retry, accurate new detail, and relaunch persistence;
- accurate Event row/detail data, cancel with no state change, confirmed close through the production-shaped delivery path, list/detail/timeline/ongoing-filter/Thing convergence, closed-state persistence, and no repeated close action;
- Event close failure/retry with visible in-flight feedback, no duplicate action, detail-owned error, unchanged canonical ongoing state after rejection, production-shaped delivery on retry, and relaunch persistence;
- accurate Thing identity/summary, real Event/Message/Update relation details, working Sheet return, and relaunch persistence;
- one-start PR Sidebar navigation across accurate Message, Event, Thing, Channel, and Settings destinations, with the selected Simplified-Chinese Messages title still visibly readable, non-overlapping, and clickable beside a real `99+` unread badge;
- decryption lifecycle through real Settings controls: invalid input stays in its Sheet, valid protected material persists without echo, blank Save preserves it, and explicit Delete survives relaunch;
- protected-material persistence failure remains owned by the Sheet, does not expose configured state after restart, and only a real retry may configure it;
- encrypted-message purpose outcomes: a wrong valid-length key preserves the safe fallback, the matching key recovers the exact canonical title/body across relaunch, and corrupt ciphertext remains safely unreadable;
- real Event page visibility controls, both persisted directions, and an accurate reachable destination;
- inline invalid-server feedback through real controls;
- candidate Gateway registration rejection with no local commit, inline ownership, retry, data re-scoping, and relaunch persistence;
- local Gateway commit failure with immediate and process-relaunch rollback, followed by a successful real-control retry;
- native-minimize the real main window and restore that same usable window through the primary status-item action without duplicating its session or content; then close during in-flight refresh and restore one functional window through the real localized right-click Open Main Window action and again through the primary left click, preserving the same session and accurate Store result.

The 19 host-path/command/state methods are named `legacyDiagnostic...` and no longer use XCTest's `test...` discovery convention. Their green results never counted as product coverage. The twenty-five current journeys use the App-owned quality session and real accessibility UI; they do not read the App database or state files from the host test process. Thing filter, exact relation detail, delete/commit/relaunch and registered deep-link purposes are now covered in the App-owned Thing journey. The remaining macOS gaps are Notification Center card interaction/reconciliation under the current system accessibility boundary, physical accessibility/performance, and real external-provider delivery; they are not inferred from fixture, identifier, simulator, or component evidence.

## Run

Use the zero-retry repository runner. It first proves that the interactive console is unlocked, then holds a scoped `caffeinate` assertion so a long lane cannot idle back to the login screen. XCTest observes a quiet window and closes the exact macOS system `Problem Reporter` application before and after every journey; the outer runner also closes the exact process before/after the batch and on interruption/exit. It terminates only stale test-built PushGo/Runner processes at the batch boundary, preventing an interrupted prior run's background App from blocking activation. Therefore an App crash cannot leave its delayed system dialog above the next journey without paying the instability cost of relaunching the UI-test Runner for every method. A crashed journey remains `FAILED`; closing the system dialog is test-environment cleanup, never a retry or a route to green. A locked console or a dialog that cannot be closed is explicitly `BLOCKED` instead of becoming a misleading product failure:

```bash
./scripts/run_macos_ui_tests.sh
```

Set comma-separated `TEST_SCOPES` for a focused run. The runner requires a normal local development signature. A local automation-authorization or pre-execution runner failure is test-system `BLOCKED`; an executed oracle failure is product `FAILED`; neither is retried into green. Core semantic/storage checks remain in `PushGoAppleCoreTests`, but they do not replace the missing physical macOS UI journeys.
