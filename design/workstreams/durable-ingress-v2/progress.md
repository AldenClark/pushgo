# Durable ingress v2 progress

Historical 1.3.0 build 90 status: local release gates are complete. Physical-device, upload, review, and production validation remain not run and are not publication prerequisites for that release decision. The 2026-10-13 snapshot slice and its separate evidence limits are recorded below.

Completed:

- target architecture and Dev Flow design validation;
- repository/Git/Swift concurrency baseline;
- overlapping user-owned deletion/UI work identified and preserved;
- rollback-journal App Group ingress database with atomic payload/ACK, pull claims, fencing, legacy import, quarantine, retry, and dependency-safe maintenance;
- NSE display path reduced to durable ingress plus bounded fallback; short direct messages never perform client pull;
- canonical materialization, durable asynchronous ACK, strict v2 page barrier, derived-work outbox, UI database observation, ingress-first bootstrap, scene/tap/background wakeups;
- iOS/macOS/watchOS integration and source-boundary guardrails.
- self-waking canonical/ACK retry deadlines with one rearming controller wake task;
- typed BGAppRefresh stage outcomes, joined ACK/derived work, and synchronous exactly-once expiration arbitration;
- durable, non-fatal rollback-shadow failure health for the binary downgrade gate;
- emergency sidecar fallback for every encoded ingress whose primary journal write throws, with future-schema preflight before DDL;
- Xcode 27 AppDelegate isolation warnings removed and the concurrency allowlist reduced to documented legacy/FFI ownership invariants.

Verified locally:

- `swift test`: 373 tests in 35 suites passed;
- generic unsigned iOS, macOS, and watchOS builds passed, including embedded NSE/Widget validation;
- stale lease, ACK dependency, legacy import, cleanup, cross-Gateway hint isolation, derived-work, and architectural boundary tests passed.
- focused ingress/ACK/derived/BG lifecycle suites: 64 tests passed after the retry/background changes;
- generic unsigned Xcode 27 iOS, macOS, and watchOS builds passed with no product warnings;
- `scripts/concurrency_audit.sh` passed.
- final `scripts/apple_concurrency_gate.sh` passed 384 tests in 35 suites plus unsigned iOS, macOS, and watchOS builds, privacy, locked dependency, workflow security, rollback compatibility, and concurrency controls;
- macOS functional automation and watchOS automation smoke passed;
- an iOS 27 temporary simulator was created for the audit, the full UI set ran, and the three-language localized primary-screen regression passed after MainTab began observing late notification-open requests directly from the observable navigation controller;
- stable version metadata is `1.3.0` build `90`, with English, Simplified Chinese, and Traditional Chinese update notes present.

Operational validation not run and not required for publication:

- physical-device NSE expiration, protected-data, force-quit/relaunch, BGAppRefresh denial/expiration;
- signed archive/upload, physical-device delivery, App Store review/release, cross-system production, and canary telemetry;
- Historical note: macOS UI XCTest was blocked before test startup by an active LocalAuthentication session. Authorization was restored on 2026-08-28; the App-owned core aggregate now includes ten journeys including provider refresh recovery, while durable-ingress-specific close-during-ingress evidence remains pending.

Constraints:

- local commits are authorized; push, tag, signing/upload, release, App Store action, and live Gateway migration are not authorized;
- unrelated in-progress deletion/UI changes remain user-owned and must not be reverted.

## 2026-10-13 Apple system snapshot simplification

This slice changes only the shared Apple system snapshot. Canonical notification persistence and ACK, the other derived-work kinds, and NSE responsibilities remain unchanged. Delivery scope is one local commit of this slice; push and publication remain unauthorized.

- `canonical_derived_work` now holds one fixed `system_snapshot` identity without a message foreign key. A changed notification batch marks it dirty once in the same canonical transaction. Per-message snapshot jobs and their completed history are removed.
- Existing synchronous save/read/delete/settings/Focus refresh timing is retained. Canonical mutations invalidate unfinished snapshot work in their own transaction; explicit Focus rebuilds invalidate before their immediate rebuild. Idle synchronous operations do not create another queued pass. The existing >10-message asynchronous delete path now uses the durable worker instead of an unowned refresh task.
- The existing worker rebuilds current canonical data. Completion and retry retain lease-owner fencing and compare the claimed generation with the current generation; newer changes remain immediately pending. No second scheduler, cache, or cross-process wait protocol is introduced.
- Removed the zero-interval refresh policy, reason plumbing, and unused last-refresh recording. The actual hourly health check and six-hour snapshot age limit remain. The shortcut summary enum moved into the existing shortcut output source; the deleted policy file was removed from SwiftPM and Xcode registration.
- Migration `v26_output_system_snapshot_work` drops completed legacy snapshot rows and merges pending/leased/retry-wait rows into one due rebuild. Other kinds retain their exact identity, generation, lease, retry state, and metadata. Canonical records and read state are not replayed. This supports forward upgrade, not an older binary reopening or concurrently writing the v26 database.

The focused 26-test run passed and verifies exact Message/Event/Thing summaries and counts, transaction rollback when snapshot enqueue fails, immediate read/delete results, changes during old success/failure, actual SIGKILL after claim followed by recovery without new ingress, mixed v25 migration/reopen, and host/NSE interleaving with Widget decoding and sensitive/decrypt-failed content filtering. The exit test advances only its persisted test lease deadline after real process termination; production lease duration is unchanged. Privacy follows real normalized settings and decryption behavior, without inventing a privacy-switch flow.

The concurrency fixture pauses a real child process after snapshot construction and before the cross-process file lock. Initial in-process pausing could block unrelated parallel tests and was replaced; child timeout or abnormal exit now explicitly fails. Other fixture corrections retained exact product oracles: event-title patches carry the payload key, Widget targets use the canonical local UUID, and the kill fixture waits for SIGKILL rather than racing a normal exit. First-failure logs remain in `build/quality-results/apple-system-snapshot-20261013/`.

A one-off negative control made completion ignore newer generations. The new-ingress race failed on both counts (1 instead of 2) and the missing new title. After restoring production code, the focused suite passed again. Independent read-only reviews found no consequential product or final-test defect; they are source review, not additional runtime evidence.

The first `quality_changed.sh` invocation used Xcode's Python 3.9 and failed three script compatibility checks before product execution. Selecting the installed Python 3.14 resolved that cause: 275 script tests, required static contracts, migration probes, and 467 Swift Testing cases in 44 Core suites passed. The impact selector conservatively recommended `release` for the shared Store and SwiftPM/Xcode registration changes. That lane was then interrupted at the user's pause request during its iOS positive batch (observed exit 75). The original `changed/apple-release-summary.json` is retained: its generic exit handler labels the interruption `FAILED` with a product-oracle reason, although no product assertion failed before interruption. `changed-interruption-annotation.json` records the cause, retains completed claims, and leaves the unfinished scope unaccepted. Resumption runs the required PR and performance lanes without restarting the full Release matrix.

Final working-tree checks:

- The pre-commit identity check matched all nine product, test, and build-registration entries (including the deleted policy file) against `candidate-source-manifest.json`, with base `e6d1dd968442b70c7d6c87a0dbf5056e9b633288` unchanged. The only additional tracked changes are the three capability, disposition, and progress records for this slice. No tests were repeated for local commit closure.
- `scripts/quality_test.sh pr`: `PASSED/PASSED`, no incomplete claims or test-system issue IDs. Core and localization passed; iOS ran all four selected journeys and macOS ran its selected navigation journey, with zero retries. Native results: `ios/run-1-20261013-111515.xcresult` and `macos-ui/run-20261013-112406.xcresult` under `build/quality-results/`.
- `scripts/quality_test.sh performance`: `PASSED/PASSED`, no incomplete claims or test-system issue IDs. All 11 opt-in scale tests passed, including 100k Store/upgrade and 10k Watch/concurrency correctness. The iOS and macOS 1k Store cold-process-to-accurate-content journeys each passed. Native results: `ios/run-1-20261013-112903.xcresult` and `macos-ui/run-20261013-113020.xcresult`. Both slow-load controls and the iOS wrong-body control rejected their deliberate faults; these are test-system sensitivity results, not extra product passes.
- Performance reused the fresh PR build products with unchanged product/test/build-source hashes. `candidate-source-manifest.json` binds that frozen working tree; `final-impact-plan.json` remains `READY` with the conservative `release` recommendation. Complete Release acceptance remains unclaimed. Existing SwiftPM warnings about unhandled `p2` fixture resources were observed and left outside this slice.
- Receipts and original logs are indexed by `build/quality-results/apple-system-snapshot-20261013/verification-summary.md`. These checks establish bounded host/Simulator correctness and existing regression ceilings, not a before/after performance improvement.

The existing host/NSE publication window remains: an older host build can temporarily overwrite an NSE increment until canonical import/rebuild converges. Database commit and snapshot publication are not atomic, and synchronous/background rebuilds may overlap. Physical Widget/Siri/Shortcut UI, APNs, OS background scheduling, power loss/real disk exhaustion, signed release, and old-binary downgrade are not inferred from host tests.


## 2026-10-14 V2-only network Pull cutover

All new Apple apps require V2 Pull and explicit ACK. Legacy destructive network requests, fallback flags and new legacy staging producers are removed. Existing destructive payloads retain import/materialization/retry across reopen with no new network fetch or ACK. Direct single-item ACK, immutable destination/contract recovery, normal NSE-to-host journal, emergency sidecar and bounded registered rollback shadows keep their separate consumers. The contract in `design/apple-durable-ingress-final-design.md` now makes importer removal conditional on settlement across all supported upgrade sources and no late producer/artifact; an elapsed release alone is insufficient.

Final local evidence is segmented, not a new full PR pass: 29 affected Core harness cases and 25 service cases passed after preserved first failures; the production Apple Service/Store/ACK journey against loopback Gateway SQLite passed 1/1; iOS/macOS/watchOS build-for-testing passed. The complete first Core receipt remains FAILED. All Apple UI/a11y runtime remains BLOCKED by the locked console with zero execution; Watch's new silent-wakeup journey is compiled only. Exact counts, causes, source identity and remaining physical/production gaps are in the same-date quality workstream entry and `build/quality-results/v2-pull-required-20261014/verification-summary.json`. This batch is local and uncommitted; prior local-commit authorizations do not authorize committing it.


Unlocked native follow-up (2026-10-14): the requested Gateway upgrade copy is now localized. Bounded evidence completed as initial iOS3 + repaired iOS2, macOS2, Watch silent V2/Store/ACK/reopen/upgrade1, and iOS zh-Hans accessibility5 task1. Preserved preparation failures were traced to automatic default-Gateway requests in local quality sessions and a DEBUG v17 fixture that retained the v27 Watch column while rewinding its ledger. Repairs isolate only automatic quality bootstrap and rewind the fixture schema; production migration, explicit Gateway execution, local ingress, ACK and error oracles remain. Two focused preparation regressions passed. Earlier full-Core FAILED receipt is unchanged; previous protocol evidence is reused only for unchanged behavior. See the latest quality workstream entry and `native-unlocked/verification-summary.json`; Windows native and physical/production boundaries remain unverified. No commit, push or release.
