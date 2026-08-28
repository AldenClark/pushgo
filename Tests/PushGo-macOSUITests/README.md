# PushGo macOS UI quality suite

## Current executable scope

The target now exposes five XCTest-discoverable journeys:

- App-owned empty-state launch and functional message-list readiness;
- real Sidebar navigation across primary destinations;
- real Settings entry to the decryption overlay;
- inline invalid-server feedback through real controls;
- close/status-item/reopen window lifecycle with one functional window.

The 18 host-path/command/state methods are named `legacyDiagnostic...` and no longer use XCTest's `test...` discovery convention. Their green results never counted as product coverage, and the former macOS/serial automation shell runners have been removed. The bundle compiles, but local runtime enumeration is still `BLOCKED` by macOS UI automation authorization; it is not evidence that physical discovery or execution passed. Missing macOS Event/Thing detail, page-visibility persistence, Gateway commit, notification action, and performance journeys remain explicit gaps until replaced by App-owned user-purpose tests.

## Run

Use the repository quality wrapper for classified evidence. Direct Xcode runs are diagnostic only:

```bash
xcodebuild -project pushgo.xcodeproj \
  -scheme PushGo-macOS \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/pushgo-macos-uitests \
  test -only-testing:PushGo-macOSUITests
```

The runner requires a normal local development signature. A local automation-authorization failure is test-system `BLOCKED`; it must not be retried into product green. Core semantic/storage checks remain in `PushGoAppleCoreTests`, but they do not replace the missing physical macOS UI journeys.
