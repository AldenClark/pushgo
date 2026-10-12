# Durable ingress v2 progress

Status: 1.3.0 build 90 local release gates are complete. Physical-device, upload, review, and production validation remain not run and are not publication prerequisites for this release decision.

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
