# Apple ingress batching and drain hardening progress

## Status

P0 and the foreground/NSE-backed P1 drain slice are implemented and verified. Physical-device timing is complete for 50, 200, and 1,000 short and long pending entries.

## Completed

- Reproduced the read regression through initial notification persistence, explicit local read, and duplicate request replay.
- Confirmed notification normalization always supplies `isRead = false` and the duplicate-request update previously overwrote the stored value.
- Changed duplicate-request persistence to preserve monotonic local read state while still refreshing canonical content.
- Extended the existing duplicate-request test to cover the read/replay sequence.
- Reviewed the prior durable-ingress task and its architecture/implementation records.
- Traced current v2 pull, strict journal write, canonical write, derived-work creation, count refresh, GRDB observation, and visible-tab reload paths.
- Confirmed v2 pages can contain 200 items and the current implementation performs item-by-item journal and canonical commits.
- Confirmed ordinary inbox application does not claim rows even though the schema and parent design require `applying` leases and stale-result fencing.
- Confirmed the parent design's `IngressDrainCoordinator` was not added and current full-sync coalescing neither joins callers nor covers targeted/inbox paths.
- Recorded the bounded page pipeline, bulk title resolution, single-flight/lease ownership, UI refresh coalescing, fault tests, and rollout/rollback decision.
- Added notification-specific canonical batch commits with ordered per-item outcomes and one derived-worker kick per batch.
- Added process-local joinable inbox single-flight, durable `applying` claims, lease generations, expired-owner takeover, and fenced completion/retry.
- Added progressive 64-item first commit followed by bounded 200-item commits.
- Batched fenced journal completion and limited legacy compatibility import to once per drain; physical traces showed these were required to avoid a nominally batched drain degrading back toward per-item latency.
- Replaced cancel/restart count and visible-tab refresh with request-coalescing trailing loops.
- Added a lightweight inline notice as the first message-list row, driven by durable queue counts: delayed reveal for fast drains, a 10-second no-progress warning, a temporary retry notice, and brief completion confirmation. Numeric progress and the progress bar remain intentionally absent from the visual treatment.
- Added localized English, Simplified Chinese, and Traditional Chinese status copy, Reduce Motion behavior, and bounded VoiceOver announcements.
- Preserved monotonic read state for duplicate request replay.
- Added DEBUG-only physical-device fixture, timing, and cleanup controls. Fixture canonical rows use a dedicated channel and are deleted after each run.

## Verification

- New batch ordering, concurrent single-flight, and stale lease-generation tests passed.
- New durable due/outstanding count and exact multi-batch progress-sequence tests passed.
- Full `swift test` passed: 388 tests in 35 suites; opt-in 100,000-item runtime cases remained skipped by their normal environment gate.
- Debug and Release generic iOS builds passed, including the embedded watch target.
- The final iOS Simulator visual lifecycle check used 1,000 pending messages with 1,400 Chinese characters each. It confirmed the lightweight status appeared as the first list row, pushed message content below it without overlap, omitted numeric/bar progress, and disappeared after all 1,000 rows became visible. All simulator fixture canonical rows, journal rows, and emergency shadows were then removed.
- Physical iPhone 16 final-code results on an exact 1,000-message UI baseline:

  | Body | Pending | Cached UI | First canonical commit | First batch visible | All pending visible | Full drain/maintenance |
  | --- | ---: | ---: | ---: | ---: | ---: | ---: |
  | short (9 characters) | 50 | 0.247 s | 0.350 s | 0.391 s | 0.391 s | 0.421 s |
  | short (9 characters) | 200 | 0.264 s | 0.447 s | 0.503 s | 0.757 s | 0.843 s |
  | short (9 characters) | 1,000 | 0.266 s | 0.791 s | 0.837 s | 2.693 s | 3.124 s |
  | long (1,400 Chinese characters) | 50 | 0.255 s | 0.476 s | 0.529 s | 0.529 s | 0.523 s |
  | long (1,400 Chinese characters) | 200 | 0.258 s | 0.589 s | 0.646 s | 1.319 s | 1.408 s |
  | long (1,400 Chinese characters) | 1,000 | 0.249 s | 0.990 s | 1.039 s | 5.776 s | 6.237 s |
- Every physical fixture channel was removed. Final due-pending check returned zero.
- `git diff --check` passed.

## Next

- The provider network page still uses the existing per-item strict journal acceptance path before the new batched canonical drain. A future page-journal transaction must preserve emergency sidecars and ACK barriers and is intentionally not folded into this foreground/NSE change without its dedicated fault-injection oracle.

## Evidence limits

- Physical timings are single cold-launch samples on the connected iPhone 16, not distribution percentiles. Real provider traffic added a small number of non-fixture messages in early discarded/diagnostic runs; final 1,000-entry reruns had exact 1,000-message baselines and exact fixture counts.
- The final review is in the same working context. No independent reviewer was authorized, so common-mode review risk remains explicit.
