# Apple ingress batching and drain hardening

> Status: audit complete; P0 implemented; foreground/NSE-backed P1 canonical drain implemented and physically verified. Provider page-journal batching remains gated on its emergency-sidecar fault oracle.
>
> Decision date: 2026-08-26
>
> Parent architecture: `design/apple-durable-ingress-final-design.md`

## 1. Decision

Preserve the existing acceptance boundaries and use the following target architecture for the two pieces of the durable-ingress design that the audit found incomplete:

1. process each v2 provider page through bounded **page transactions**, not one durable/canonical transaction per item;
2. give canonical inbox application a real **single-flight, fenced drain owner**, not overlapping read-then-apply loops.

The rollout is deliberately staged. The implemented first slice combines canonical batching with fenced, single-flight local inbox ownership; shipping either of those alone would retain duplicate work or one-at-a-time visibility. Provider network pages now use the same bounded canonical committer, but their preceding strict journal acceptance remains per item. Replacing that acceptance path with one page transaction is a second slice gated on an emergency-sidecar/partial-write fault oracle. Network full-sync joining and bounded bulk fallback-title lookup stay with that second slice as well.

The P0 read-state rule is independent and is applied now: delivery replay may refresh canonical content, but persisted `isRead == true` is monotonic and cannot be reset by an incoming notification normalized as unread.

## 2. Repository evidence

The pre-change provider page path performed the following work once per item:

- `ProviderIngressCoordinator.syncProviderIngressOutcome` calls `journalPulledPayload` in the item loop;
- after the page is durable, it awaits `hooks.persistPayload` and `hooks.applyPersistenceResult` for every item;
- `NotificationPersistenceCoordinator` may perform an individual entity/message title lookup before every write;
- `LocalDataStore.persistNotificationMessageIfNeeded` opens one GRDB write transaction, creates four durable derived-work rows, and kicks the derived worker for every item;
- `NotificationIngressController.applyProviderIngressPersistenceResult` schedules a count refresh for every persisted or duplicate item;
- each canonical transaction advances `message_store_revision`, and the visible tab reloads on every observed committed revision.

A v2 page contains up to 200 items. The result is therefore O(page size) strict journal commits, canonical commits, worker kicks, count refresh requests, and UI observation opportunities. Running the item writes concurrently is not a fix: the actors and SQLite writers serialize them while order, cancellation, and ACK accounting become harder to reason about.

The pre-change inbox drain also diverged from the parent design:

- `mergeInbox` reads `pending`/`retry_wait` rows without claiming them;
- a second lifecycle trigger can read the same rows before the first loop marks them terminal;
- the schema already has `applying`, `lease_owner`, `lease_until_ms`, and `lease_generation`, but the ordinary ingress apply path never claims with them;
- completion and retry accept any row in `pending`, `retry_wait`, or `applying` and do not compare owner/generation;
- `isFullSyncInFlight` covers only untargeted network sync, returns `skipped` instead of joining, and does not protect inbox merge or targeted sync;
- the `IngressDrainCoordinator` required by the parent design was never added.

Canonical idempotency prevents most duplicate rows, but it does not prevent repeated normalization, database lookups, derived-work generation bumps, count refreshes, or duplicate network resolution. The P0 read regression was one user-visible consequence of that replay surface.

## 3. Protected invariants

The P1 implementation must preserve all parent invariants, especially:

- no ACK without a durable validated entry or deterministic-discard tombstone;
- no page advance before the current page is classified, canonically resolved, and its ACK barrier succeeds;
- no network, Spotlight, Widget, Live Activity, or system-snapshot work inside the journal or canonical transaction;
- canonical commit remains the UI visibility boundary;
- a failed canonical transaction leaves journal work retryable and sends no premature ACK;
- stale lease completion cannot settle work reclaimed by another owner;
- a process kill after canonical commit produces idempotent replay, not duplicate display or read-state regression;
- legacy destructive pull remains isolated and retains its documented crash window.

## 4. P1-A: bounded page pipeline

For each v2 page, use this sequence:

1. Pull and decode the response outside database locks.
2. Sanitize every item and construct the immutable outer delivery identity.
3. In one App Group journal transaction, classify the page into validated entries or deterministic-discard tombstones and create the corresponding ACK intents. Return an ordered result for every item.
4. Claim the validated local-apply rows through the drain coordinator.
5. Prepare canonical messages outside the GRDB transaction. Resolve fallback titles with bounded bulk lookups grouped by message/event/thing identity; do not load a projection detail once per item.
6. In one private-GRDB transaction, apply the page and return an ordered outcome per item: persisted main, persisted pending, duplicate request, duplicate semantic message, deterministic reject, or transient failure.
7. The same transaction maintains immediately visible projection heads, operation/delivery dedupe, and one set of durable derived-work intents per affected canonical identity. It must reuse the notification-specific conflict rules, including monotonic read state; it must not call generic `saveMessagesBatch`.
8. After commit, kick the derived worker once and schedule counts once. GRDB observation should emit one committed generation for the page.
9. Settle claimed journal rows in one fenced transaction using each row's owner and lease generation, then run the existing ACK batch barrier. Only then may `has_more` advance.

The batch is exactly one provider page, with a hard maximum of 200. Do not combine pages into an unbounded transaction. Direct notification/tap materialization remains a targeted one-item fast path using the same committer.

### Journal failure and emergency sidecars

The batch API must preserve the current fail-closed emergency behavior. Prepare all versioned entry envelopes before the transaction. If the primary journal transaction throws, persist the existing per-entry emergency envelopes with full synchronization. A partially written sidecar set does not make the page ACKable; retry imports are idempotent by immutable identity and fingerprint. Identity conflicts remain ordinary rejected results and are not converted into storage-failure shadows.

### UI refresh contract

Correctness continues to come from `message_store_revision` observation. The visible-tab refresh owner should use a request-coalescing loop (`refresh requested` + one owned task), not cancel an in-flight load on every revision. A revision arriving during a refresh requests exactly one follow-up refresh. Imperative count refresh is an accelerator and fires once per committed batch.

The message screen may expose drain progress as a non-blocking, notification-style overlay, but the overlay is not a second source of truth and does not participate in message sorting, unread state, or persistence. Its state is derived from durable journal counts:

| Durable state | UI state |
| --- | --- |
| Due work starts | Delay presentation to avoid flashing for fast drains: 350 ms for 500+ rows, otherwise 900 ms |
| Work remains after the delay | Insert a lightweight one-line status as the first list row; batch commits continue to update later rows |
| No progress event for 10 seconds | Change the one-line copy/tone to a slower-than-usual warning |
| Only leased or delayed-retry rows remain | Show a retry-scheduled notice, then dismiss it after 4 seconds; the retry wakeup remains owned by the controller |
| All rows settle | If the overlay was visible, show completion for 800 ms and dismiss; if the drain completed before reveal, show nothing |

Presentation is inline, scrolls with the list, and does not block taps or pull-to-refresh. It intentionally omits numeric progress and a progress bar because those add visual weight without changing the user's decision. VoiceOver announces initial presentation, slow/waiting transitions, and completion, but not each batch update.

## 5. P1-B: single-flight and fenced ownership

Use `ProviderIngressCoordinator` as the sole owner of local journal materialization in each host process instead of adding a parallel coordinator with overlapping ownership.

- Darwin notifications, bootstrap, scene activation, remote notification callbacks, BG refresh, retry timers, and manual sync submit work to this coordinator.
- Concurrent callers join the owned run. Requests merge monotonically: targeted identities are prioritized, and `allowFallbackPull` may upgrade from false to true but never downgrade an active request.
- The journal claim transaction changes due `pending`/`retry_wait` rows, or expired `applying` rows, to `applying(owner, lease_until, lease_generation + 1)` and returns the lease token.
- Completion/retry/discard operations compare row ID, expected state, owner, and generation. A stale result updates zero rows.
- Claim at most 64 local rows at a time and continue while immediately due work remains or until the caller's explicit budget expires.
- Do not hold an ingress-apply lease across provider network I/O. An unresolved wakeup hands off to the separately fenced pull claim, releases/retries the local apply claim, performs the request outside locks, and re-enters through durable journal state.
- A process kill is recovered by lease expiry. Process-local single-flight is a latency/duplication optimization; the durable lease is the correctness fence.

As a second-slice follow-up, network full sync also needs an owned joinable task. Returning `skipped` merely because another full sync is active gives pull-to-refresh and background completion the wrong result. Targeted delivery sync remains separately fenced by the existing pull-claim identity and can queue behind, or be satisfied by, the active reconciliation run.

## 6. Rejected changes

- **Parallel per-item persistence:** SQLite still serializes writes and the change expands cancellation/order races.
- **Generic `saveMessagesBatch`:** it does not implement notification-request outcomes, pending Thing dependencies, ACK accounting, or notification replay rules.
- **Debounce-only UI fix:** it hides some visual churn but leaves strict per-item journal/canonical transactions and duplicate work intact.
- **Process-local boolean only:** it cannot fence overlapping processes or reject stale completion, and repeats the incomplete `isFullSyncInFlight` pattern.
- **Lease-only change without batching:** it fixes ownership but not the reported one-at-a-time visibility.
- **Moving derived work back into the commit path:** this reintroduces the earlier notification-display regression.
- **ACK before canonical resolution to improve speed:** this breaks the current v2 page barrier and zero-loss oracle.

## 7. Verification gates

The complete target architecture requires the following failure-sensitive tests. The first-slice gates cover canonical ordering/replay, local single-flight, lease takeover, full regression builds, and the physical-device probes; page-journal and full-sync-joining gates remain required before the second slice is enabled.

- a 200-item page produces one journal page commit, one canonical commit/observation, one count-refresh request, and ordered per-item outcomes;
- persisted, pending-entity, duplicate-request, duplicate-operation, duplicate-message, deterministic-reject, and transient-failure mixtures preserve ACK eligibility item by item;
- a read message remains read through duplicate request replay inside a batch;
- derived-work rows remain durable and are kicked once, while external projection APIs are not awaited by canonical commit;
- page N+1 is not pulled before page N terminal settlement and ACK success;
- primary journal failure, partial emergency-sidecar failure, canonical rollback, and process kill retain the correct durable identities without ACK loss;
- three simultaneous lifecycle triggers claim and apply each entry once;
- expired leases are reclaimed, while a late completion from the old generation changes zero rows;
- unresolved wakeup resolution performs no network wait while holding an ingress-apply lease;
- a revision during an active UI refresh causes one follow-up refresh instead of cancellation starvation;
- focused 200-item and 1,000-pending-entry runtime probes record journal-to-observation latency and transaction counts without relying on a brittle wall-clock-only unit assertion.

Run the full Swift package suite, unsigned iOS/macOS/watchOS builds, rollback compatibility, concurrency gate, and final source-boundary review. Physical-device foreground/NSE/BG timing remains an external evidence gate.

## 8. Rollout and rollback

No journal schema migration is required for claim ownership because the columns and generations already exist. The first slice keeps the current provider journal acceptance and single-item targeted path, while switching ordinary inbox application and provider canonical persistence to the bounded committer. Switch provider page-journal acceptance only after the emergency-sidecar state-machine tests pass.

Rollback disables the batch caller and drain owner but must leave existing journal rows, ACK intents, and canonical dedupe readable. It must never restore ACK/projection work to the NSE critical path or delete pending/applying work. Observability should record page size, journal/canonical transaction count, journal-to-observation latency, claimed/reclaimed/stale-settlement counts, and refresh coalescing without payload content.
