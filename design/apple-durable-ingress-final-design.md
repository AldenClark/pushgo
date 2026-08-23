# Apple Durable Ingress And Canonical Storage Final Design

> Status: **Implemented and locally verified in the working tree; physical-device and release gates remain**
>
> Decision date: 2026-08-20
>
> Scope: iOS, macOS, watchOS host apps and their notification service extensions
> Delivery rule: the complete target architecture ships as one gated release; a bounded N-to-N-1 rollback bridge is retained for 35 days, but there is no supported intermediate production architecture.

## 1. Final decision

Keep the existing two-store product boundary, but replace the fragile handoff mechanism:

```text
APNs / private transport
        |
        v
NSE or host-app ingress
        |
        | one short durable transaction
        v
App Group ingress journal
        |
        +--> durable ACK outbox ------> Gateway ACK worker
        |
        | idempotent replay
        v
host-app private canonical database
        |
        +--> UI observation (correctness path)
        +--> durable derived-work outbox
                 +--> Spotlight
                 +--> Widget/system snapshot
                 +--> Live Activity / Watch mirror
```

The App Group database is **not** a second canonical message database. It is a compact durable handoff journal. The host app remains the sole owner of canonical Message/Event/Thing state and the sole writer of shared system projections.

The implementation must make these changes together:

1. Add the shared ingress journal and its migration/import logic.
2. Move NSE ACK and derived work off the notification-display critical path.
3. Make the notification completion gate synchronous and exactly-once.
4. Add a single-flight host-app drain coordinator with targeted materialization.
5. Make canonical commit the UI visibility boundary and move all external projections to a durable outbox.
6. Drive message UI from database observation instead of refresh timing.
7. Add background reconciliation as an accelerator, never as the correctness mechanism.
8. Remove the three legacy file state machines from normal operation after the same-release import succeeds, while retaining registered rollback-only shadows for the bounded binary rollback window.

## 2. Why the current implementation is not sufficient

The following findings are verified against the current source, not inferred from the user report.

### 2.1 NSE presentation is blocked by post-durability work

`Shared/Services/NotificationServiceProcessor.swift` currently performs this sequence before returning content:

1. Resolve and prepare content.
2. Write `NotificationIngressInbox`.
3. Update the shared system snapshot.
4. Wait for a Widget reload handshake.
5. Await Spotlight indexing.
6. Await Gateway ACK, whose request timeout is 15 seconds.
7. Deduplicate delivered notifications.
8. Optionally enrich media.

`Extensions/PushGoNSE-iOS/NotificationService.swift` calls the system `contentHandler` only after that method returns. Therefore ordinary direct short messages do **not** call `/messages/pull`, but they can still be delayed by ACK and projection work. The earlier hypothesis “all short messages are blocked by self-hosted `/messages/pull`” is rejected; the verified blocker is work after the durable inbox write.

### 2.2 Expiration fallback is not synchronously guaranteed

`serviceExtensionTimeWillExpire()` currently cancels processing and creates a new Swift `Task` that awaits an actor-based delivery gate before calling the handler. Apple calls this method because the extension is about to be terminated. Creating more asynchronous work at this boundary does not guarantee it will run.

### 2.3 Host-app canonical persistence has an oversized completion boundary

`LocalDataStore.persistNotificationMessageIfNeeded` commits the canonical row first, then awaits:

- app search index updates;
- metadata index rebuild;
- Core Spotlight;
- notification context snapshot;
- Live Activity work;
- system-surface snapshot refresh.

Callers interpret completion of the whole method as persistence completion. Foreground notification presentation and notification actions can therefore wait for unrelated derived work after the database commit.

### 2.4 ACK is still awaited in foreground paths

`NotificationIngressController.persistNotificationIfNeeded` persists a direct notification and then awaits `ackDirectProviderIngressIfNeeded`. `UNUserNotificationCenterDelegate.willPresent` awaits that entire operation before invoking its presentation completion handler.

### 2.5 Refresh ordering can expose stale UI

On iOS scene activation, `scheduleMessageListRefresh()` currently runs before the asynchronous inbox merge. A refresh can therefore finish against the old canonical state, while the later merge has no deterministic observation boundary for the already visible query.

### 2.6 The shared handoff is split across three process-local actors and files

Normal ingress correctness is currently distributed across:

- `NotificationIngressInbox`: one binary plist per notification;
- `ProviderDeliveryAckFailureStore`: separate marker files and leases;
- `ProviderWakeupPullClaimStore`: a third set of files and leases.

Actors serialize only within one process. The host app and NSE are different processes. The stores implement their own locking and transitions, but cannot atomically express “payload durable + ACK eligible + pull claim resolved.” Corrupt inbox files are silently deleted during enumeration, and a default 256-entry scan is one pass rather than a drain-until-empty contract.

### 2.7 Existing shared SQLite stores do not solve this boundary

- `SharedImageCache` has a shared SQLite WAL metadata cache, but it is purgeable and cannot own durable ingress.
- `WatchLightNotificationStore` is a watch-specific projection store, not the cross-process delivery journal.
- The host-app canonical GRDB database is intentionally app-private after `migrateSharedDatabaseArtifactsIntoAppLocal`; opening it from an NSE would restore cross-process coupling to the main database.

The new database therefore replaces the three ingress file stores. It is not a fourth parallel mechanism and does not reuse a purgeable cache.

### 2.8 Bootstrap currently lets unrelated recovery precede ingress merge

`Apps/PushGo-iOS/App/AppEnvironment.swift::performBootstrap` currently awaits `pendingLocalDeletionController.restoreAndReconcile()` before `mergeNotificationIngressInbox`. The deletion controller drains due work and its channel-history branch may await `channelCommitHandler`, which can perform server unsubscribe/cleanup. A slow or hung maintenance request can therefore delay both the first inbox merge and the readiness flag that owns the main UI. This is an integration defect independent of NSE delivery latency; the final design requires local ingress drain to precede all network-capable maintenance and gives it a separate readiness boundary.

## 3. Architecture decision record

### Context

APNs presentation has a strict, system-controlled deadline. Host apps and extensions have independent lifetimes. Background execution is opportunistic. At the same time, Gateway ACK is allowed only after the client has a recoverable copy.

### Decision

Use a dedicated App Group SQLite ingress journal with very short transactions and a host-app private canonical database. A durable journal commit is the client-acceptance boundary; a canonical database transaction is the UI-visibility boundary; all network calls and nonessential projections run asynchronously from durable outboxes.

### Journal mode decision

The ingress journal uses:

```sql
PRAGMA journal_mode = DELETE;
PRAGMA synchronous = EXTRA;
PRAGMA fullfsync = ON;
PRAGMA foreign_keys = ON;
PRAGMA temp_store = MEMORY;
```

Connections use `SQLITE_OPEN_FULLMUTEX`, `BEGIN IMMEDIATE` for writes, and bounded busy handling. Every opened connection sets these durability pragmas and reads them back on that same live connection; any mismatch fails closed before accepting ingress. `EXTRA` is required because SQLite documents the additional containing-directory synchronization after rollback-journal unlink that `FULL` alone does not provide. Each SQLite attempt has a 200-ms busy timeout and contention receives at most two short exponential+jitter retries. After payload encoding succeeds, any thrown primary-journal storage failure—including exhausted contention, open/configuration failure, corruption, or a future schema—persists the same versioned identity/payload into an atomically replaced emergency sidecar. A normal `false` result such as an identity conflict is not shadowed. Durable acceptance is reported only after strict `F_FULLFSYNC` succeeds for the temporary file, installed destination, emergency directory, and parent directory. There is no ordinary-`fsync` success fallback. Journal startup imports sidecars idempotently before ordinary drain work. A future schema is detected before journal-mode changes or DDL, leaving the newer database untouched while the sidecar waits for a compatible reader.

This small database deliberately does **not** use WAL:

- each NSE transaction is only a few kilobytes;
- there is no long-running journal read transaction;
- rollback journal removes checkpoint ownership and WAL-family lifecycle from a termination-prone extension;
- SQLite disclosed and fixed a rare multi-connection WAL-reset corruption race in 2026; the OS SQLite version cannot be upgraded by this app independently.

The main app's existing private GRDB databases are not changed by this decision.

The emergency sidecar is not a competing steady-state ingress architecture or another database. It is a bounded last-resort write-ahead envelope for primary-journal storage failure, uses the same immutable entry identity and payload fingerprint, and is removed only after verified journal import. An already-existing destination is not accepted by filename alone: it must decode and match schema, full entry/ACK identity, required state, and recomputed payload fingerprint; an invalid destination is atomically replaced through the same strongly synchronized path. Malformed, identity-mismatched, or newer records are quarantined without ACK.

### Rejected alternatives

1. **Open the canonical database from NSE.** Rejected because it couples extension deadlines, schema migration, locks, and derived-state code to the main store.
2. **Keep the three file stores and only move ACK to a `Task`.** Rejected because it improves latency but retains non-atomic cross-process state and silent-corruption behavior.
3. **Reuse `SharedImageCache`.** Rejected because caches are purgeable and have unrelated retention/checkpoint behavior.
4. **Create a fourth ingress WAL database beside the file stores.** Rejected. The journal is a replacement, with legacy import only.
5. **Make BGAppRefresh correctness-critical.** Rejected because the OS does not guarantee launch timing and force-quit can suppress background launch.

### Consequences

- Cross-database atomic commit is impossible; replay plus canonical idempotency is mandatory.
- ACK can happen before canonical materialization, but only after either a validated recoverable payload or a deterministic-discard tombstone and its ACK row are durably committed together.
- Notification display latency no longer includes Gateway latency, Spotlight, Widgets, Live Activity, or ACK.
- The host app must own migration, reconciliation, retention, diagnostics, and every shared projection write.

### Recheck triggers

Revisit this decision if Apple provides a guaranteed extension-to-app durable queue, if all supported OS releases contain the fixed SQLite version and measured rollback-journal contention exceeds the SLO, or if Gateway changes the ACK contract from durable client acceptance to canonical application commit.

## 4. Non-negotiable invariants

| ID | Invariant |
|---|---|
| A1 | Gateway ACK implies that the same transaction committed an ACK intent plus either a validated recoverable payload or a deterministic-discard tombstone. |
| A2 | If the journal commit fails, the client sends no ACK. |
| A3 | Network I/O, media download, Spotlight, Widget reload, and Live Activity calls never run inside a SQLite transaction. |
| A4 | Canonical persistence is idempotent by scoped delivery identity, message/entity ID, and notification request ID where available. |
| A5 | UI reads only canonical state, never a timing-dependent merge of canonical rows and arbitrary shared files. |
| A6 | A crash between canonical commit and journal completion causes replay, not data loss or duplicate display. |
| A7 | The NSE invokes the content handler at most once, and expiration can invoke it synchronously without awaiting an actor. |
| A8 | Darwin notifications, scene transitions, silent pushes, and BG tasks are hints; foreground reconciliation is always sufficient. |
| A9 | Deterministically rejected v2 pull items become durable discard tombstones and are ACKed to unblock the page; storage corruption or an unknown newer schema is quarantined and never ACKed. Direct invalid payloads are not ACKed. |
| A10 | Only the host app writes Widget/system snapshots. NSE never performs a read-modify-write projection. |
| A11 | Retries hold no database transaction or lock while sleeping or awaiting the network. |
| A12 | The same final semantics apply to iOS, macOS, and standalone watchOS; platform-specific projections may differ. |
| A13 | Provider arrival/canonical insertion order is not business order; observed lists use the existing semantic business-time plus stable-ID ordering contract. |
| A14 | A leased result mutates a row only when owner, lease generation, and expected state still match; stale workers have no effect. |
| A15 | For v2 bulk pull, the current page is durably classified, locally materialized, and its ACK batch resolved before the next `has_more` page is requested. |
| A16 | A successful Gateway ACK removal is evidence of prior Apple durable acceptance/discard; provider success alone never permits Gateway pull-cache deletion. |
| A17 | During the 35-day compatibility window, N emits an N-1-decodable, full-identity rollback shadow for each accepted ingress; the N importer never consumes a registered shadow, shadow-write failure fails the binary-rollback release gate, and a v2 ACK shadow is published only after local terminal commit. |

## 5. Shared ingress journal

### 5.1 Location and ownership

File name: `Library/Application Support/PushGoIngress/ingress.sqlite` inside each platform's existing App Group container.

The directory and files use `NSFileProtectionCompleteUntilFirstUserAuthentication` where the platform supports file protection and are excluded from backup. If protected data is unavailable after reboot, NSE shows fallback content, sends no ACK, and relies on Gateway retention plus foreground reconciliation.

Schema migration rules:

- only additive migrations are allowed while host app and NSE from the same release can overlap;
- both binaries understand the same current schema and the immediately previous schema;
- the host app performs migrations before normal drain;
- NSE may create an empty current schema but must never run a destructive migration;
- an unknown newer schema causes a visible fallback and no ACK.

### 5.1.1 Bounded N-1 rollback shadows

The first journal schema records `legacy_rollback_shadow_started_at_ms` and opens a 35-day compatibility window. During that window an accepted N writer also emits the exact binary-plist shapes decoded by the pre-journal (`git show HEAD`) inbox and ACK readers:

- inbox files keep the `.inboxbin` extension but use the journal's full ownership identity and payload fingerprint in their name; they never reuse N-1's delivery-only last-write-wins name;
- legacy-single ACK files use the full ACK identity and schema-3 marker format after the durable ingress transaction;
- v2 ACK files are not emitted at ingress time because N-1 has no `terminal_local` eligibility gate; they are emitted only after the canonical applied/discarded transition commits;
- completed and retry states update the same full-identity schema-3 marker.
- A current-N ingress commit never fails solely because its N-1 shadow cannot
  be written. Shadow filesystem/synchronization failures increment the durable
  `rollback_shadow_health` singleton with the last kind, reason, and timestamp;
  any nonzero count fails the binary-rollback release gate.

SQLite remains authoritative. A `rollback_shadow(kind, file_name, identity_key, created_at_ms, expires_at_ms)` registry is committed before each atomic shadow write. The N legacy importer skips registered shadows, including on repeated empty/non-empty scans, so it cannot immediately import and delete the only N-1-readable copy. An N-1 binary ignores the registry and discovers any decodable file by extension, exactly as its shipped reader did.

Shadow failure does not weaken N durability or ACK gating, but it disables binary rollback for that identity. The release gate therefore fault-injects both shadow directories and treats any physical-device write failure as a rollback-coverage failure even though the N enqueue remains accepted. Conversely, N-1 replay from a shadow may repeat canonical materialization, so canonical idempotency remains mandatory. This bridge is compatibility-only and must not become a second source of truth or a new steady-state writer architecture.

### 5.2 Logical schema

```sql
CREATE TABLE ingress_entry (
    entry_id                TEXT PRIMARY KEY,
    schema_version          INTEGER NOT NULL,
    source                  TEXT NOT NULL,
    source_base_url         TEXT,
    source_device_key       TEXT,
    resolution_state        TEXT NOT NULL,
    request_identifier      TEXT,
    delivery_id             TEXT,
    message_id              TEXT,
    entity_type             TEXT,
    entity_id               TEXT,
    payload_plist           BLOB,
    validation_state        TEXT NOT NULL,
    apply_state             TEXT NOT NULL DEFAULT 'pending',
    lease_owner             TEXT,
    lease_until_ms          INTEGER,
    lease_generation        INTEGER NOT NULL DEFAULT 0,
    apply_attempts          INTEGER NOT NULL DEFAULT 0,
    next_apply_at_ms        INTEGER NOT NULL,
    created_at_ms           INTEGER NOT NULL,
    canonical_applied_at_ms INTEGER,
    quarantine_reason       TEXT,
    discard_reason          TEXT,
    payload_fingerprint     TEXT,
    expires_at_ms           INTEGER
);

CREATE UNIQUE INDEX ingress_delivery_uidx
    ON ingress_entry(source_base_url, source_device_key, delivery_id)
    WHERE source_base_url IS NOT NULL
      AND source_device_key IS NOT NULL
      AND delivery_id IS NOT NULL;
CREATE INDEX ingress_due_idx
    ON ingress_entry(apply_state, next_apply_at_ms, created_at_ms);

CREATE TABLE ack_outbox (
    ack_id             TEXT PRIMARY KEY,
    entry_id           TEXT NOT NULL REFERENCES ingress_entry(entry_id),
    delivery_id        TEXT NOT NULL,
    base_url           TEXT NOT NULL,
    device_key         TEXT NOT NULL,
    ack_contract       TEXT NOT NULL,
    required_entry_state TEXT NOT NULL,
    state              TEXT NOT NULL DEFAULT 'pending',
    lease_owner        TEXT,
    lease_until_ms     INTEGER,
    lease_generation   INTEGER NOT NULL DEFAULT 0,
    attempts           INTEGER NOT NULL DEFAULT 0,
    next_attempt_at_ms INTEGER NOT NULL,
    last_error_code    TEXT,
    completed_at_ms    INTEGER,
    UNIQUE(base_url, device_key, delivery_id, ack_contract)
);

CREATE INDEX ack_due_idx
    ON ack_outbox(state, next_attempt_at_ms, lease_until_ms);

CREATE TABLE pull_claim (
    claim_id           TEXT PRIMARY KEY,
    delivery_id        TEXT NOT NULL,
    base_url           TEXT NOT NULL,
    device_key         TEXT NOT NULL,
    pull_contract      TEXT NOT NULL,
    state              TEXT NOT NULL,
    lease_owner        TEXT,
    lease_until_ms     INTEGER,
    lease_generation   INTEGER NOT NULL DEFAULT 0,
    attempts           INTEGER NOT NULL DEFAULT 0,
    next_attempt_at_ms INTEGER NOT NULL,
    resolved_entry_id  TEXT REFERENCES ingress_entry(entry_id),
    last_error_code    TEXT,
    UNIQUE(base_url, device_key, delivery_id, pull_contract)
);

CREATE TABLE ingress_meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
```

Payload BLOBs use the current sanitized binary-property-list representation with an explicit schema version. Tokens and passwords are never stored in the journal; ACK workers resolve credentials from the existing Keychain stores.

State values are closed enums in Swift and checked by schema-version-aware decoding:

- `resolution_state`: `direct`, `pulled`, `unresolved`;
- `validation_state`: `validated`, `rejected_deterministic`, `corrupt`, `unsupported_newer`;
- `apply_state`: `pending`, `applying`, `retry_wait`, `applied`, `discarded`, `quarantined`, `expired`;
- ACK `state`: `pending`, `leased`, `retry_wait`, `blocked_auth`, `completed`, `superseded`, `permanent_error`;
- pull-claim `state`: `pending`, `leased`, `retry_wait`, `completed`, `expired`.

ACK `required_entry_state` is `durable` for a valid direct delivery and `terminal_local` for a v2 pull page. The claim query permits `durable` after the validated journal transaction commits, but permits `terminal_local` only when the referenced entry is `applied` or `discarded`. This persisted dependency prevents the general ACK worker from racing ahead of the page coordinator.

Unknown values are not coerced to success. A newer value produces a visible fallback, no ACK, and a redacted compatibility diagnostic. `payload_plist` is non-null for `validated`; it may be null only for a durable deterministic-discard tombstone or redacted quarantine metadata. A deterministic discard stores the delivery identity, bounded reason code, schema/contract version, and payload fingerprint, never an unbounded rejected body.

### 5.3 Lease fencing

Every claim transaction increments `lease_generation` and returns `(row_id, owner, generation, lease_until)`. Completion, retry, supersession, and cancellation use compare-and-swap predicates over row ID, expected state, owner, and generation. A result from an expired lease updates zero rows and increments `stale_lease_result_rejected`; it never marks a reclaimed row complete. This rule applies independently to ingress application, ACK, pull claims, and canonical `derived_work`.

### 5.4 Identity

`entry_id` is deterministic in this order:

1. the hash of normalized immutable `(source_base_url, source_device_key, delivery_id)` when all three exist;
2. normalized message/entity semantic ID plus operation ID;
3. notification request identifier;
4. a generated UUID only when no stable identity exists.

An insert conflict merges only safe metadata and never overwrites a validated payload with an unresolved fallback payload.

Direct ACK identity is constructed only from `base_url + provider_device_key + delivery_id` carried by the immutable provider payload; missing fields never fall back to the app's current Gateway configuration or a local notification request ID. Pull identity comes from the actual request destination/device plus the outer `PullItem.delivery_id`, which is authoritative over any embedded value. URL normalization lowercases only scheme/host, preserves percent-encoded path and path case, removes the permitted trailing slash, and rejects userinfo/query/fragment. ACK batching and uniqueness include normalized URL, device key, delivery ID, and contract, so equal delivery IDs from two Gateways cannot collide.

### 5.5 Transactions

The valid direct-ingress transaction performs only:

1. validate and encode the payload before opening the transaction;
2. `BEGIN IMMEDIATE`;
3. insert-or-confirm `ingress_entry`;
4. insert-or-confirm `ack_outbox` when ACK metadata is complete;
5. increment a monotonically increasing generation in `ingress_meta`;
6. commit.

Direct invalid/unsupported payloads show a bounded fallback and create no ACK. The v2 pull-ingress transaction, by contrast, classifies every page item atomically: it writes a validated ingress row or a deterministic-discard tombstone, writes the corresponding ACK row for either class, and completes any targeted `pull_claim`. A corrupt transport body, unverifiable identity, unsupported newer contract, or transaction failure creates no ACK. Network pull occurs before the transaction and outside all database locks.

If a delivery first created a pending legacy direct-ACK row and later appears in a successful v2 pull, the pull transaction inserts the v2 ACK row and marks the pending legacy row `superseded`. A leased legacy result can settle only its old generation, so it cannot overwrite the supersession decision. This prevents two contracts from racing to own the same delivery.

### 5.6 Retention and dependency-safe cleanup

The host app is the only cleanup owner. Cleanup runs in bounded batches of 64 and never deletes `pending`, `applying`, `leased`, `retry_wait`, `blocked_auth`, or unresolved rows merely to meet a size target.

Deletion order is explicit because `ack_outbox` and `pull_claim` reference ingress entries:

1. expire unresolved pull claims only after the Gateway delivery TTL is known to have elapsed;
2. delete terminal ACK rows and completed/expired pull claims whose diagnostic retention has elapsed;
3. delete an `applied` ingress row only when it has no nonterminal ACK or pull dependency;
4. run bounded SQLite maintenance only while the host app is active and outside UI-critical work.

Default retention is seven days for applied/completed handoff rows and 30 days for redacted quarantine metadata. Quarantined payload bodies are removed at the shorter of 30 days or the configured privacy retention, while reason/fingerprint counters may remain aggregated. Canonical dedupe ledgers—not journal retention—prevent an already materialized delivery from becoming a duplicate UI item.

Rollback shadows use a separate fixed boundary: their expiry is 35 days from the first journal migration, not 35 days from each write. Registration refuses new shadows after that cutoff. Host-only bounded maintenance removes expired shadow files and then their registry rows; a failed file deletion leaves the registry row so the next maintenance pass retries without exposing the file to the current importer. After cleanup, rolling back to N-1 is unsupported and requires a forward-fix artifact with the journal reader.

Storage pressure first removes dependency-safe terminal rows and stale redacted diagnostics. If the journal still reaches its hard byte budget, new writes fail closed: NSE displays fallback and sends no ACK, leaving the Gateway copy recoverable. Accepted pending work is never evicted.

## 6. Exact end-to-end sequences

### 6.1 Direct short notification without media

```text
NSE receives APNs
  -> sanitize, decrypt, minimally validate
  -> transaction: ingress_entry + ack_outbox + generation
  -> post Darwin hint (best effort)
  -> synchronously win completion gate
  -> call contentHandler
```

ACK, Gateway pull, Spotlight, Widget reload, notification deduplication, and media are not awaited or started by the NSE. The host app or its owned background runner drains durable work later.

Target SLO, measured from NSE `didReceive` to `contentHandler`:

- p95 under 300 ms;
- p99 under 1 second;
- self-hosted Gateway latency has no effect on this direct path.

### 6.2 Notification with media

Text is durably journaled first. Media download gets its own absolute deadline derived from extension time remaining. The content handler receives:

- enriched content if media finishes within budget;
- already prepared text immediately on timeout, cancellation, or download failure.

Media failure cannot roll back ingress or ACK eligibility.

### 6.3 Wakeup-hint notification

```text
NSE receives wakeup
  -> durably append unresolved wakeup hint
  -> post Darwin hint (best effort)
  -> display bounded fallback content immediately
  -> host/owned BG worker later resolves v2 or measured legacy fallback
```

No iOS, macOS, or watchOS NSE performs provider pull, ACK, or arbitrary `URLSession` work. Host resolution acquires a fenced claim, performs network I/O outside the transaction, then atomically records the classified result and ACK dependency. If resolution fails or a peer owns the claim, the durable hint remains retryable and no ACK is sent.

### 6.4 Foreground `willPresent`

1. Materialize the targeted journal entry or direct payload into the canonical database.
2. Commit UI-required rows and derived-work intents.
3. Invoke the presentation completion handler immediately.
4. Let database observation update visible UI.
5. Kick ACK and derived workers without awaiting them.

Gateway ACK and system projections are not part of the delegate deadline.

### 6.5 Notification tap, cold launch, and action buttons

Before routing, call `materializeTarget(deliveryID/requestID)` through the single-flight drain coordinator. A successful or duplicate canonical commit allows navigation immediately. If a wakeup is unresolved, route to a stable “正在同步消息” state bound to the target identity; never navigate to a blank detail page.

Action completion handlers finish after the local canonical action transaction, not after ACK or projection work.

### 6.6 Private-channel ingress

Private transport already reaches the host app and can persist directly to the private canonical database. It uses the same `CanonicalInboundCommitter` and `derived_work` contract, but does not detour through App Group when the host app owns the active callback. If background suspension can interrupt a received-but-uncommitted callback, first persist a journal entry, then continue canonical materialization.

## 7. Host-app drain and canonical commit

### 7.1 `IngressDrainCoordinator`

One actor per host process owns drain work:

- coalesces Darwin, scene, push, BG task, and manual-sync triggers;
- supports high-priority targeted materialization for taps and foreground notification delegates;
- otherwise claims due rows in batches of 64;
- drains until no immediately due row remains, rather than stopping after 256 total rows;
- renews no lease while executing network work because canonical materialization is local;
- releases/retries rows with full jitter after transient store failure;
- marks deterministic-discard rows terminal without materialization, and quarantines only corruption or unsupported-newer state with a reason/fingerprint.

Claim transaction:

```text
pending/retry_wait + due + expired lease
  -> applying(owner, lease_until, attempts + 1)
```

Completion transaction:

```text
applying -> applied(canonical_applied_at)
```

If the process dies after canonical commit but before journal completion, the lease expires and idempotent replay returns duplicate, after which the row is marked applied.

### 7.2 Canonical transaction boundary

`CanonicalInboundCommitter.commit` performs one private-GRDB transaction containing:

- canonical Message/Event/Thing rows;
- notification request/delivery dedupe ledger;
- entity projection heads needed by immediately visible screens;
- FTS/search state required by in-app search, or a generation guaranteeing query overlay until FTS catches up;
- `derived_work` rows for all nonessential projections.

It returns as soon as the transaction commits. It does not await external frameworks.

Delayed retry or server reconciliation may commit an older business event after a newer one. Repositories therefore sort with the established semantic key (for Message, `(occurred_at, op_id)`), never SQLite row ID, notification receipt time, or projection completion time. Entity reducers reject stale generations according to the existing semantic-time contract.

### 7.3 Derived-work outbox

```sql
CREATE TABLE derived_work (
    work_id             TEXT PRIMARY KEY,
    kind                TEXT NOT NULL,
    entity_key          TEXT NOT NULL,
    target_generation   INTEGER NOT NULL,
    state               TEXT NOT NULL DEFAULT 'pending',
    attempts            INTEGER NOT NULL DEFAULT 0,
    next_attempt_at_ms  INTEGER NOT NULL,
    lease_owner         TEXT,
    lease_until_ms      INTEGER,
    lease_generation    INTEGER NOT NULL DEFAULT 0,
    last_error_code     TEXT,
    created_at_ms       INTEGER NOT NULL,
    UNIQUE(kind, entity_key)
);
```

Kinds include `ack_kick`, `app_search`, `spotlight`, `system_snapshot`, `widget_reload`, `live_activity`, `watch_mirror`, and `notification_dedup`. Latest-state projections coalesce by `(kind, entity_key)` and generation. ACK itself remains in the App Group `ack_outbox`; `ack_kick` only wakes that worker.

### 7.4 UI observation

Message lists, counts, detail existence, and search results observe the canonical GRDB database using `ValueObservation`-style repository APIs. Imperative `scheduleMessageListRefresh()` is removed from correctness paths and retained only for non-database UI state if needed.

The ordering becomes:

```text
journal drain -> canonical commit -> observation emits -> view updates
```

Scene activation starts drain first. It does not issue a speculative list refresh against the old database snapshot.

### 7.5 Foreground reconciliation order

Every cold launch and scene activation coalesces into this ordered reconciliation; repeated triggers join the same run:

1. drain existing journal rows into the canonical database;
2. enumerate `UNUserNotificationCenter` delivered notifications and re-ingest any supported direct payload whose stable identity is not in the canonical dedupe ledger;
3. call device-scoped `/v2/messages/pull` without a delivery ID and receive exactly one page;
4. in one local transaction classify every item as a validated ingress row or deterministic-discard tombstone and create that page's v2 ACK rows;
5. drain validated rows into the canonical database, then drain only that page's v2 ACK rows; if persistence, materialization, or ACK fails, stop pagination and retry later;
6. only after the page ACK barrier succeeds, request the next page when `has_more=true`;
7. start general ACK/derived workers and let canonical observations update lists, counts, search, and routes.

The page barrier is required by the Gateway's stable v2 non-destructive pull contract (see `gateway/readme.md` and `gateway/release/V1.3.0_RELEASE_AUDIT.md`): until the current page is ACKed, another pull may return the same page. Pagination therefore runs inside an owned background reconciliation worker, but its page-to-page dependency is intentionally sequential. No UI delegate, notification handler, or app launch readiness gate awaits the network portion.

This order recovers a direct notification when the NSE displayed fallback because the App Group was temporarily unavailable, and also discovers retained server work that never produced a usable local notification. Server reconciliation is network-dependent acceleration; steps 1-2 remain useful offline.

Bootstrap priority is a hard integration rule: after the canonical database opens and small local UI-suppression snapshots load, the first awaited correctness operation is local ingress drain. Pending-deletion execution, channel sync/unsubscribe, search-index repair, image cleanup, and other maintenance start afterward and cannot be awaited ahead of ingress. UI readiness is split into local-store/ingress readiness and maintenance readiness; a slow network reconciliation cannot leave the main UI behind a launch `ProgressView` or hide an already canonical message.

Legacy destructive `/messages/pull` cannot provide a crash-safe response-to-local-commit boundary and is therefore not used for background bulk reconciliation. It remains only as an explicitly measured compatibility fallback for an old Gateway after the v2 capability check fails; its response is journaled immediately, and the residual server-response/client-crash window is reported as a legacy protocol limitation. The release compatibility matrix must name the minimum Gateway version that supports the final crash-safe v2 contract.

## 8. ACK worker

ACK is a durable asynchronous job, not a call-stack continuation from notification display.

Rules:

1. Claim due ACK rows with a fenced `(owner, lease_generation)` in a short journal transaction, joining the referenced entry to enforce `required_entry_state`.
2. Resolve the current Gateway credential outside the transaction.
3. Perform `/messages/ack` outside the transaction with an absolute timeout.
4. Mark complete, retry, auth-blocked, or permanent-contract-error in another transaction.
5. Honor server retry hints; otherwise use exponential backoff with full jitter.
6. Batch compatible delivery IDs by `(base_url, device_key, ack_contract)`.
7. A missing/rotated credential does not discard the row; foreground configuration changes wake it.
8. Validate batch response counts: `requested_count` must match the request and `0 <= removed_count <= requested_count`; malformed or impossible counts are contract errors.
9. On a known fresh first attempt, full removal completes the batch; partial or ambiguous removal remains retryable and records that ambiguity. After an earlier ambiguous/partial result, a later valid `removed_count=0` is idempotent success because all rows may already have been removed. The legacy single-ACK `false` result is accepted only under the same prior-ambiguity rule.
10. A v2 ACK row supersedes a pending legacy row for the same immutable `(base_url, device_key, delivery_id)` identity.

Worker opportunities, in priority order:

- an ordinary Swift task while the host app is active;
- a bounded UIKit background assertion only to finish work already in flight as the app backgrounds;
- one `BGAppRefreshTask` registration;
- next foreground launch.

No notification/UI delegate awaits the worker. An active BGAppRefresh handler
does join the owned ACK task so its completion status reflects work performed
inside that background opportunity. Background execution affects ACK latency,
not correctness.

## 9. Background execution contract

The implementation adds one iOS app-refresh identifier and its required project capability/Info.plist declarations. It registers before launch completion and schedules the next request when handling the current one.

The BG task reschedules its successor first, then performs a bounded budget.
Each stage returns `.succeeded` or `.failed`; cancellation is a distinct runner
outcome:

1. drain ingress journal;
2. drain a small ACK batch;
3. drain and await a small derived-work batch inside the BG task lifetime;
4. set completion exactly once;
5. update the durable-work hint used to choose the next earliest permitted request.

Canonical or ACK retry creation reports the BG task unsuccessful rather than
silently treating a completed closure as success. Expiration cancels owned work,
releases or lets leases expire, and synchronously claims an
`OSAllocatedUnfairLock` completion gate before scheduling the main-actor
`setTaskCompleted(success: false)` call. Normal completion uses the same gate,
so completion remains exactly once and expiration wins a race with late work.

Foreground correctness also owns its own retry clock. `DurableIngressJournal`
exposes the earliest `retry_wait.next_apply_at`; `NotificationIngressController`
chooses the minimum of that deadline and the ACK/lease deadline, then owns one
cancellable wake task. New work cancels/rearms it, an earlier existing deadline
is never replaced by a later one, and firing runs both canonical merge and ACK
drain before calculating the next deadline. Thus a transient canonical failure
progresses without another Darwin notification or lifecycle transition.

Constraints:

- `beginBackgroundTask` is used only by the host app to finish already-started work; app extensions cannot call it.
- silent pushes and `BGAppRefreshTask` are opportunistic and may be delayed.
- user force-quit, denied background refresh, low-power policy, or system pressure must not lose data; foreground reconciliation remains complete.
- `backgroundRefreshStatus`, low-power mode, scheduling failure, launch delay, and expiration are telemetry/degraded-mode inputs, never acceptance predicates.
- background `URLSession` is not introduced for small ACK requests.
- workers do not use `Task.detached`; SQLite and network work run in owned, cancellable tasks on non-main executors, and no blocking SQLite call is isolated to `MainActor`.

## 10. Shared projections and badges

The host app becomes the single writer of:

- `PushGoSystemSurfaceSnapshot`;
- notification context snapshot;
- Widget projection/reload generation;
- Spotlight projection state;
- app badge derived from canonical unread count.

NSE may set a content badge for the notification being displayed, but it does not read-modify-write the shared snapshot. Widgets may render the last host snapshot and optionally show a conservative “pending updates” indicator derived from the journal generation; they never treat journal payloads as canonical entities.

This removes lost updates between concurrent NSE instances and the host app.

## 11. Failure matrix

| Failure point | Required outcome |
|---|---|
| App Group unavailable/protected | show fallback, no ACK, trace redacted reason |
| Journal open/configuration/write failure, including busy beyond bounded retries | atomically persist and fsync emergency sidecar; only if both journal and sidecar fail, show fallback and send no ACK |
| Journal commit succeeds, process killed | host app later drains; ACK remains durable |
| Content handler wins before optional ACK task | notification displays; ACK worker resumes later |
| Pull times out | unresolved row/claim retry, no ACK, explicit fallback |
| Canonical DB unavailable | journal retry with lease/backoff; UI shows recovery state |
| Crash after canonical commit | duplicate replay marks journal applied |
| Derived framework fails | canonical UI remains correct; `derived_work` retries |
| ACK 401/403 | keep row blocked for credential refresh; do not spin |
| Deterministically rejected item in a valid v2 page | commit discard tombstone + v2 ACK; do not poison the page forever |
| Corrupt journal/storage or unknown newer schema | quarantine, no silent deletion, no ACK |
| Direct invalid/unsupported payload | bounded fallback, no ACK |
| v2 page ACK fails while `has_more=true` | stop; never request the next page until this page's ACK barrier succeeds |
| Old leased result arrives after reclaim/supersession | fenced update affects zero rows; current owner/state remains unchanged |
| More than 256 pending entries | batch 64 and continue until empty/budget expired |
| Background task never launches | foreground drain completes all durable work |

## 12. One-release migration and cutover

“一步到位” means one supported target architecture and one release gate, not one unreviewable commit. Implementation may use ordered work packages, but production enablement happens only after every package and gate passes.

### Required work packages

1. **Shared journal kernel**
   - raw SQLite wrapper, schema, bounded transactions, file protection, quarantine, test clock/fault hooks;
   - shared by iOS/macOS/watchOS host and NSE targets without adding GRDB to NSE.
2. **NSE critical-path rewrite**
   - transaction-only durable boundary;
   - synchronous lock-based exactly-once delivery gate;
   - bounded media branch and immediate unresolved fallback.
3. **Canonical committer and observation**
   - narrow commit result;
   - canonical dedupe/projection transaction;
   - database observations for lists/counts/search/tap routing.
4. **Workers and background support**
   - ACK and derived outboxes;
   - single-flight drain;
   - UIKit assertion and BGAppRefresh lifecycle.
5. **Legacy import and removal**
   - import inbox files, ACK markers, and pull claims idempotently;
   - mark `legacy_import_complete` only after verification;
   - normal ownership switches exclusively to the journal; bounded registered N-1 shadows are compatibility artifacts, not independent state machines;
   - retain read-only legacy recovery for one release, then remove.
6. **Telemetry and fault tests**
   - all acceptance gates in this document.

### Source-level implementation map

The following file map is the implementation boundary, so coding does not need to rediscover component ownership:

| Action | Repository path / responsibility |
|---|---|
| Add | `Shared/Services/DurableIngressJournal.swift`: raw SQLite schema, migrations, transactions, claims, cleanup, fault hooks |
| Add | `Shared/Application/IngressDrainCoordinator.swift`: single-flight targeted/batch materialization |
| Add | `Shared/Repositories/CanonicalInboundCommitter.swift`: narrow canonical transaction and duplicate result |
| Add | `Shared/Services/IngressAckWorker.swift`: leased ACK attempts and retry classification |
| Add | `Shared/Services/DerivedWorkWorker.swift`: projection coalescing and retry |
| Add | `Shared/Application/AppleBackgroundWorkCoordinator.swift`: BG registration, UIKit assertion, cancellation/completion gate |
| Rewrite | `Shared/Services/NotificationServiceProcessor.swift` and all platform NSE `NotificationService.swift` files: journal critical path and synchronous delivery gate |
| Rewrite | `Shared/Application/NotificationIngressController.swift`, `Shared/Services/ProviderIngressCoordinator.swift`, and `Shared/Repositories/LocalDataStore.swift`: targeted drain, canonical boundary, observation |
| Integrate | iOS/macOS/watchOS `AppEnvironment.swift` and app delegates: foreground reconciliation and worker lifecycle |
| Configure | `Package.swift`, `pushgo.xcodeproj/project.pbxproj`, iOS `Info.plist`, entitlements: shared source membership, App Group access, BG task declaration |
| Retire after verified import | `Shared/Services/NotificationIngressInbox.swift` and the ACK/pull file-state sections of `ProviderDeliveryAckFailureStore.swift` |

The first implementation change should add a source-boundary test that fails if an NSE imports GRDB/canonical repositories, calls ACK/projection APIs before `contentHandler`, or if a legacy normal-path file writer remains reachable when `durable_ingress_v2` is enabled.

### Cutover gate

A single compile/local feature gate, `durable_ingress_v2`, defaults off in development builds until all packages pass. In the release artifact every new writer uses v2. The only legacy-format writes are registered, full-identity rollback shadows within the fixed 35-day window; there is no runtime ownership fallback to the legacy stores.

The launch/update handshake is:

1. NSE may create an empty current journal and write to it before the updated host app has launched;
2. the host app opens/migrates the journal, idempotently imports every legacy file, then records `legacy_import_complete`;
3. for the compatibility release, foreground reconciliation continues scanning the legacy directories and imports any late file from an older already-running process by per-file identity;
4. a later release may delete the read-only importer only after telemetry/source gates show no late legacy files.

The bundled release is eligible only when:

- app and every bundled NSE have the same supported schema range;
- canonical observation and workers are registered;
- no unregistered legacy writer remains reachable in tests/source-boundary checks;
- the actual N-1 `StoredEntry` and schema-3 `StoredMarker` decoders can read N shadows, and current-N scanning leaves those shadows intact.

At runtime, schema/import failure makes the app present a recovery error and keeps old data read-only. NSE failure shows fallback and sends no ACK. Neither side may split new writes between architectures.

### Mixed-version compatibility matrix

| Participant combination | Required behavior | Guarantee |
|---|---|---|
| New NSE runs before new host app's first launch | NSE may create current journal and append; host later migrates/opens and drains | crash-safe |
| Old already-running process writes a late legacy file | compatibility-release foreground importer scans by stable identity and imports idempotently | crash-safe after file fsync under existing legacy limits |
| N binary is rolled back to N-1 within 35 days | N-1 scans full-identity `.inboxbin`/`.ackbin` shadows; canonical replay is idempotent | local handoff readable; v2 ACK never precedes N terminal commit |
| NSE sees an unknown newer journal/schema state | show fallback, write nothing, ACK nothing | Gateway copy retained |
| New Apple app + v2-capable Gateway | detect by successful endpoint semantics; use non-destructive page/ACK barrier | crash-safe |
| New Apple app + Gateway returning exact `404 route_not_found` for v2 | use measured legacy fallback; journal response immediately | not crash-safe in response-to-local-commit window |
| Pending legacy direct ACK followed by v2 pull of same delivery | v2 ACK atomically supersedes legacy ACK; lease fencing rejects stale result | one active ACK contract |

Compatibility is capability-based, not inferred from a version string. The minimum documented Gateway release is an operational shorthand; the client fallback decision remains the exact endpoint/response contract.

### Rollback

Binary rollback to the immediately preceding build is supported only inside the 35-day bridge window and only for identities whose registered shadow write succeeded. The compatibility oracle is the actual N-1 behavior: enumerate every matching extension, decode the old `StoredEntry`/schema-3 `StoredMarker`, and ignore the new SQLite registry. Full-identity filenames avoid N-1's historical destructive delivery-ID merge. Current N deliberately leaves these files untouched.

The boundary is explicit: the window starts at first journal migration, is not extended by later writes, and host maintenance deletes expired files in bounded batches. After that cutoff the migration is forward-only; use a forward-fix/emergency artifact that retains the current/previous journal reader, local drain, and ACK suppression. The kill switch may disable new NSE journal writes and network reconciliation but leaves Gateway retention intact and presents degraded fallback. Canonical schema additions are not destructively rolled back. Returning to concurrent ownership in the three old file stores is never a rollback path.

## 13. Observability and privacy

Record monotonic timestamps and redacted IDs for:

- NSE receive;
- validation complete;
- journal commit complete/fail;
- content handler called and winning path;
- app drain trigger/claim;
- canonical commit/duplicate/fail;
- database observation emission;
- ACK claim/start/result;
- v2 page pull/classify/materialize/ACK-barrier/advance;
- deterministic-discard tombstone count by bounded reason;
- legacy-ACK-to-v2 supersession and stale leased-result rejection;
- late legacy-file imports, schema cohort, capability fallback, and rollback/degraded mode;
- derived-work result;
- journal depth, oldest age, quarantine depth, and lease recovery count.

Never log notification bodies, full URLs with credentials, Gateway tokens, passwords, provider tokens, or raw payload BLOBs. Diagnostics use a keyed/fixed-length fingerprint and normalized error code.

Initial SLOs:

| Measurement | Target |
|---|---|
| Direct short NSE receive -> handler | p95 < 300 ms, p99 < 1 s |
| Active app journal commit -> UI observation | p95 < 300 ms |
| Notification tap -> target materialized or explicit syncing state | p95 < 500 ms local path |
| Journal commit success -> eventual canonical row | 100% before expiry under recoverable storage |
| ACK without journal commit | 0 |
| Duplicate canonical rows/display | 0 |

Targets must be validated on the oldest supported physical iPhone, a current iPhone, Apple Watch, and macOS; Simulator alone is insufficient for background/NSE timing.

## 14. Verification and acceptance gates

### Unit and state-machine tests

- deterministic identity and duplicate merging;
- all journal and ACK transitions, lease expiry, and retry jitter;
- lease generation fencing for ingress, ACK, pull, and derived work;
- schema current/previous/newer handling;
- sync delivery gate exactly-once under simultaneous normal and expiration calls;
- projection coalescing by generation;
- deterministic v2 rejection creates an ACKable tombstone while corruption/newer schema/direct invalid input does not ACK;
- the general ACK worker cannot claim a v2 row before its entry is `applied`/`discarded`, but may claim a valid direct row after durable journal commit;
- page `has_more` cannot advance before the current page's ACK barrier;
- legacy direct ACK is superseded by later v2 pull without a stale-lease overwrite.

### Concurrency and fault-injection tests

- host app and 2-4 simulated NSE processes writing concurrently;
- process kill before/after every transaction boundary;
- SQLite busy, full disk, protected data, read-only directory, truncated journal, and schema mismatch;
- canonical crash between commit and journal completion;
- ACK timeout, partial ACK, auth rotation, 429/5xx, and network loss;
- 1,000 pending entries with continuous new arrivals;
- foreground notification while scene activation drain is running;
- a hung channel unsubscribe/pending-deletion recovery does not delay first ingress drain, canonical observation, or main UI readiness;
- tap/cold launch during unresolved pull;
- media timeout and extension expiration.

### Native gates

- Swift package tests with strict concurrency and warnings as errors;
- iOS, macOS, and watchOS app/NSE builds;
- real-device notification service extension tests;
- real-device BGAppRefresh launch and expiration tests;
- source-boundary test proving NSE does not link/open the canonical GRDB store;
- source-boundary test proving no normal path owns legacy inbox/ACK/claim files and no unregistered legacy-format write exists outside the bounded inbox/ACK rollback bridge;
- mixed-version launch tests covering new-NSE-before-host and late legacy-file import.

### Acceptance oracle

For every injected failure, compare these durable facts rather than log text:

1. journal row and ACK eligibility;
2. canonical row/dedupe ledger;
3. handler invocation count;
4. derived-work state;
5. Gateway pull/ACK state.

The cross-system zero-loss oracle is: if Gateway no longer holds a delivery because of client ACK, Apple must already hold either a canonical row, a recoverable validated journal row, or a durable deterministic-discard tombstone for the same immutable delivery identity. A provider-success record is insufficient evidence. The harness fails on any identity present in neither side, even if logs claim success.

## 15. Red-team / blue-team review record

### Round 1: latency and cancellation

**Red:** Moving ACK into a plain `Task` is cosmetic; the extension can be killed and the task disappears. The current expiration callback also creates a task when no time remains. Derived projections can still hide behind a persistence API.

**Blue:** ACK becomes a durable outbox row committed with ingress. No presentation caller awaits it. `contentHandler` and BG completion use synchronous `OSAllocatedUnfairLock` claim transitions callable directly from expiration. Canonical commit returns before `derived_work` execution; BGAppRefresh later joins the derived worker only for honest task reporting.

**Verdict:** accepted. This produced invariants A1, A7, A11 and the narrowed commit API.

### Round 2: shared-state corruption and “why another database?”

**Red:** The app already has shared files and SQLite caches. Adding a WAL database may create a fourth mechanism, checkpoint races, and schema/version coupling. WAL itself received a 2026 multi-connection corruption fix that may not exist in every supported OS.

**Blue:** The journal replaces all three normal-path file stores; cache databases remain unrelated. The canonical store stays private. Because the ingress workload is tiny, the journal uses rollback journal + `synchronous=EXTRA` and `fullfsync=ON`, no WAL/checkpoint path, additive schema compatibility, same-connection pragma readback, and bounded busy time.

**Verdict:** accepted with design change from WAL to rollback journal. Reuse of image cache and main GRDB was rejected.

### Round 3: ACK-before-canonical and background denial

**Red:** ACK after journal commit can delete the Gateway copy before the message appears in the app. If BGAppRefresh never runs or the app is force-quit, the user may still see a notification but not a row.

**Blue:** The journal is a non-purgeable durable acceptance log, not a cache. Foreground bootstrap, scene activation, tap, and notification delegate paths all run the same idempotent drain. Targeted tap materialization precedes navigation. Background tasks only reduce lag. Storage failure sends no ACK.

**Verdict:** accepted, conditional on real-device force-quit/relaunch and targeted-materialization gates.

### Round 4: overload, poison data, and projection consistency

**Red:** A fixed 256-entry limit can strand old work; poison payloads can loop forever; concurrent NSE projections can lose updates; retries can monopolize the main actor. An unrelated bootstrap worker can also await network cleanup before inbox merge and keep the entire UI in a loading state.

**Blue:** Drain runs batches until empty/budget expiration; deterministic v2 rejections become ACKable discard tombstones while corruption/newer schemas quarantine without ACK; only host app writes projections; journal and worker actors perform blocking SQLite/network work off the main actor; UI observes canonical GRDB state. Bootstrap loads only required local suppression state before ingress and launches network maintenance independently afterward.

**Verdict:** accepted. Silent deletion and NSE projection writes are forbidden.

### Round 5: missed local write, old Gateway, and cleanup races

**Red:** If the App Group is protected or busy, a displayed direct notification may never enter the journal. Bulk legacy Pull is destructive, and an eager cleanup pass could remove the only ACK/pull dependency before canonical materialization.

**Blue:** Foreground reconciliation first drains local work, then re-ingests delivered notification payloads, then executes a per-page v2 classify/materialize/ACK barrier before following `has_more`. Cleanup has a dependency order and cannot evict pending work. Legacy destructive Pull is isolated as a measured old-Gateway compatibility limitation rather than represented as crash-safe.

**Verdict:** accepted with an explicit minimum-Gateway compatibility matrix and fault test covering server response/process kill/local commit.

### Round 6: Dev Flow contract, fencing, and rollback challenge

**Red:** “ACK after durable write” is still ambiguous for poison v2 items; a stale lease can overwrite a reclaimed row; a legacy direct ACK can race the v2 page ACK; and an emergency downgrade to an old binary can strand already-ACKed journal-only rows. Treating `has_more` as ordinary pagination can repeatedly fetch page one forever.

**Blue:** Split validated acceptance, deterministic discard, and corruption into distinct states; add lease generations and CAS settlement to every leased table; make v2 ACK supersede legacy ACK for the immutable identity; serialize each v2 page behind its materialize/ACK barrier; and declare the schema/ACK cutover forward-only with a v2-capable emergency artifact.

**Verdict:** accepted after design changes. These are stable-contract and data-lifecycle constraints, not optional implementation details.

### Round 7: shared-store contention, poison head blocking, derived retry, and BGTask challenge

**Red:** App and NSE can collide on the App Group SQLite writer; a short busy timeout can still lose the displayed notification. A malformed or future-schema row at the head can block later valid rows. Canonical commit can succeed while Spotlight, metadata, Live Activity, or system-snapshot work fails permanently. A background handler can complete twice, wait too long to resubmit, or ignore expiration. A payload identity that omits Gateway/contract scope can merge unrelated deliveries.

**Blue:** The journal retries bounded busy failures and, after successful payload encoding, falls back on every thrown primary-store failure to an atomically replaced, file-and-directory-fsynced emergency sidecar that is imported on the next compatible open. Future schema is rejected before DDL and ordinary identity-conflict `false` results are never shadowed. Claims overscan around quarantined rows, cap one pass at 10,000 entries, and a late legacy scan remains idempotent. Canonical ingress and derived work each expose durable retry deadlines and own cancellable timer wakes independent of new ingress. BG stages return typed outcomes, join ACK/derived work, resubmit at handler start, share a synchronous cancellation/completion gate, and report canonical, ACK, derived, or expiration failure exactly once. Journal identity includes Gateway, device, contract, and delivery identity, with a payload fingerprint for incomplete attribution.

**Verdict:** accepted after executable fault and lifecycle tests. Physical-device scheduling, storage protection, NSE expiration, ActivityKit rejection, and force-quit behavior remain release evidence—not assumptions made from Simulator results.

### Round 8: destructive compatibility pull, NSE network isolation, and ACK authority

**Red:** A caller that disables fallback could still reach the legacy destructive route through a defaulted helper; an NSE wakeup pull could consume most of its presentation deadline; a legacy response could be deleted server-side before canonical insertion; and an ACK lease validated only against its own outbox row could be detached from the accepted ingress identity.

**Blue:** `allowLegacyFallback` is threaded through every resolver boundary and covered by route-reachability tests. All three NSE implementations durably write a hint and immediately return fallback content; a source guard rejects pull/ACK/`URLSession` regressions. Every legacy response item is journaled with full outer identity before canonical work and creates no client ACK. ACK claim now joins and verifies the referenced ingress schema, full ownership identity, required state, payload fingerprint, and decodability. Legacy terminal settlement uses an exact full-identity SQL transition instead of a bounded scan.

**Verdict:** accepted for the v2 and reachable legacy client paths. The old destructive protocol still cannot eliminate the interval in which the server commits deletion but its response bytes never reach the client; that is an explicit compatibility limitation, not a property attributed to v2.

### Round 9: power-loss and pre-existing sidecar challenge

**Red:** SQLite rollback mode with `FULL` can omit the containing-directory synchronization after journal unlink. Ordinary `fsync` is not Apple's strongest persistence request. A crash-created or corrupted destination sidecar could be mistaken for an already durable record merely because its filename exists, causing later quarantine after Gateway ACK.

**Blue:** The live SQLite connection requires `DELETE + synchronous=EXTRA + fullfsync=ON` and reads all values back before acceptance. Emergency fallback requires `F_FULLFSYNC` on the temporary file, installed file, directory, and parent; any failure returns `enqueue=false`. Existing destinations are decoded and checked against schema, entry/ACK identity, state, and recomputed payload fingerprint; mismatch triggers strongly synchronized atomic replacement. Fault tests force the real SQLite contention path and inject file, directory, and corrupt-existing-sidecar failures.

**Verdict:** accepted for the locally testable durability contract. `F_FULLFSYNC` remains a platform request rather than a mathematical guarantee; physical-device storage-protection, latency, and controlled power-cut evidence remain release gates.

## 16. Dev Flow validation and evidence status

The design was revalidated using the Dev Flow routes selected for `persisted-data`, `distributed-state`, `migration`, `ordering`, and `version-compatibility` risk:

| Method | Challenge applied | Result |
|---|---|---|
| Repository grounding | Re-read current bootstrap, deletion recovery, ingress, ACK, and stable v2 contract paths; moved this authority into the `pushgo` Git root | passed; current bootstrap ordering defect is explicitly covered |
| Requirements/state refinement | Separated presentation, durable acceptance/discard, canonical visibility, ACK, and projections; enumerated closed states and invalid transitions | passed after tombstone, page barrier, and fencing changes |
| Cross-participant flow | Checked Apple journal/canonical facts against Gateway pull retention and ACK deletion | passed with the zero-loss oracle in section 14 |
| Parallel expand/contract + mixed versions | Exercised new NSE/old process, old Gateway, unknown schema, superseded ACK, and emergency downgrade | passed only with the forward-only rollback artifact and compatibility importer |
| Weak-oracle challenge | Rejected log/status-only success and defined durable identity reconciliation | passed in source/state tests; cross-process Gateway/Apple harness is not run |
| Background-execution specialist review | Checked registration, rescheduling, expiration, foreground completeness, and task-assertion scope | passed in code/build review; real-device gates remain required |
| Independent clean-context review | Separate Apple-ingress and cross-system reviewers challenged journal contention, identity, poison ordering, background lifecycle, derived work, ACK ownership, Gateway retention, destructive fallback reachability, and power-loss boundaries | passed after Round 9 fixes; findings were converted into focused and integration tests |
| Identity-ledger fallback | Formal ontology review lacked a separate domain expert; froze full Gateway URL/device/delivery/contract identity and prohibited lossy merge or inferred ACK source | conservative fallback applied; domain-owner review remains advisable during implementation review |

Evidence labels are intentionally narrow:

| Evidence | Status |
|---|---|
| Current-source and stable-contract facts | VERIFIED by source inspection on 2026-08-21 |
| Architecture/state/migration document closure | PASSED |
| Product implementation | IMPLEMENTED in the working tree through 2026-08-21; not committed, signed, or released |
| Swift package tests | PASSED on the final working tree: 24 XCTest + 365 Swift Testing = 389 tests under `swift test`; focused journal, canonical-derived-work, background-lifecycle, provider-ingress, corrupt-sidecar replacement, ACK-identity, and NSE network-boundary suites are included |
| Runtime-quality tests | PASSED: opt-in 100,000-item canonical-store/upgrade/search/projection/write workload and 10,000-item watch snapshot suite (10/10); final 100,000-message batch write completed in about 50.42 s while 1,840 main-thread ticks continued, with approximately 22.9 ms maximum sampled stall |
| Apple target builds | PASSED without signing for generic iOS Simulator, macOS, and watchOS Simulator destinations; embedded NSE/Widget validation succeeded. Project targets enable warnings-as-errors; forcing the setting across dependency packages exposes third-party Textual/GRDB flag conflicts rather than a product-source warning |
| Physical-device NSE/BG/force-quit tests | NOT RUN |
| Cross-system Gateway/Apple fault harness | NOT RUN |
| Live strangler/canary evidence | NOT RUN; no release action was authorized |

The implementation is locally verification-ready, not release-ready. Physical-device NSE expiration/storage protection, BGAppRefresh denial/expiration, ActivityKit rejection, force-quit/relaunch, mixed-version/downgrade, cross-system hard-kill, signed archive, and canary gates remain external evidence requirements.

## 17. Release-enablement checklist

Production enablement may begin when the owner confirms the following unchanged assumptions and the external gates above pass:

- host-app canonical database remains private;
- Gateway ACK continues to mean durable client acceptance;
- all Apple targets can add the shared raw-SQLite journal source and matching App Group entitlement;
- the one-release cutover may add an iOS BGAppRefresh identifier;
- old file stores may be retired after idempotent import.

No unresolved architecture blocker remains. The implementation preserves the stable v2 contract, forward-only reader compatibility, and the acceptance oracle above. Exact SLO thresholds are provisional until baseline measurement, but they do not alter the component boundaries or correctness invariants.

## 18. Primary references

- Apple, [UNNotificationServiceExtension](https://developer.apple.com/documentation/usernotifications/unnotificationserviceextension)
- Apple, [serviceExtensionTimeWillExpire](https://developer.apple.com/documentation/usernotifications/unnotificationserviceextension/serviceextensiontimewillexpire())
- Apple, [Choosing Background Strategies for Your App](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app)
- Apple, [Extending your app's background execution time](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time)
- Apple, [Configuring app groups](https://developer.apple.com/documentation/xcode/configuring-app-groups)
- Apple, [`fsync(2)` and `F_FULLFSYNC`](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fsync.2.html)
- SQLite, [Write-Ahead Logging](https://www.sqlite.org/wal.html)
- SQLite, [PRAGMA synchronous](https://www.sqlite.org/pragma.html#pragma_synchronous)
