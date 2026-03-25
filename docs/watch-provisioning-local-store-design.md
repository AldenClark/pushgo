# Watch Provisioning Local-Store Design

## Status
- Proposed architecture.
- This document defines how watchOS should own and consume provisioning state after it is synchronized from iPhone.
- It does not change the product invariant that iPhone is still the source of truth for `serverConfig`, `notificationKeyMaterial`, and channel passwords.

## Problem Statement
The current standalone watch path is more complex than it needs to be because provisioning state is split across:
- in-memory `AppEnvironment` fields
- watch local database records
- iPhone-to-watch transport state

That split creates three failure classes:
- runtime reads can observe stale or partially applied state
- provisioning export can mix different sources of truth
- business failures such as decrypt failure are tempted to trigger transport recovery paths

The product requirement is valid:
- iPhone owns provisioning data entry and edits
- watch keeps mirror and standalone modes
- watch must work independently in standalone mode once provisioning is applied

The architecture must therefore change, not the requirement.

## Core Decision
watchOS must treat its local database as the only runtime read source for provisioning state.

That means:
- iPhone-to-watch communication only writes provisioning state into watch local storage
- watch runtime code only reads provisioning state from watch local storage
- decrypt failure, subscription failure, notification handling failure, and pull failure must not trigger ad hoc reads back from iPhone
- version ordering is enforced only at provisioning apply time

## Architectural Invariants

### 1. Ownership
- iPhone remains the product-level owner of provisioning state.
- watch becomes the runtime owner of the last successfully applied provisioning snapshot.

### 2. Single Read Source
- watch runtime reads must only use locally persisted provisioning state.
- runtime code must not combine in-memory fields with local DB rows to construct effective provisioning state.
- runtime code must not query `WCSession` or reachability to decide which provisioning data to use.

### 3. Full-Snapshot Apply
- iPhone sends a full provisioning snapshot, not a partial patch.
- watch applies the full snapshot transactionally.
- channel removals are expressed by absence from the new snapshot, not by a follow-up delete command.

### 4. Monotonic Versioning
- watch must reject any incoming provisioning snapshot whose version is older than or equal to the currently applied local version.
- only a strictly newer snapshot may replace current local provisioning state.

### 5. Semantic Ack
- watch provisioning `ack` means "snapshot was accepted and committed to local storage".
- transport receipt alone is never success.

### 6. No Runtime Pullback
- business/runtime failures do not trigger "ask iPhone for config again" behavior.
- transport recovery remains the responsibility of the sync subsystem, not the message-processing or decryption path.

## Proposed Data Model

### Existing Persisted Business Data
The current store already persists most of the needed payload:
- `serverConfig`
- `channel_subscriptions` including passwords
- watch sync generation state

Those records should remain the effective runtime source for:
- gateway base URL
- gateway token when standalone needs it
- `notificationKeyMaterial`
- channel ID, display name, password

### New Provisioning Metadata Record
Add a dedicated watch-local provisioning metadata record so version ordering is explicit and does not depend on transport runtime files.

Recommended fields:
- `schema_version`
- `provisioning_generation`
- `content_digest`
- `applied_at`
- `mode_at_apply`
- `source_control_generation`

This metadata may live in:
- a dedicated `watch_provisioning_state` table, or
- an equivalent persisted config object if the repository already has a strong typed config store for watch-only metadata

The important constraint is not the exact table name; it is that the last applied provisioning version is durable and queryable without touching watch-connectivity runtime files.

## Provisioning Snapshot Contract
iPhone must export a complete standalone provisioning snapshot containing:
- `schema_version`
- `provisioning_generation`
- `content_digest`
- `mode = standalone`
- `serverConfig`
- `notificationKeyMaterial`
- `channels[]`

Each `channels[]` entry must contain:
- `gateway`
- `channel_id`
- `display_name`
- `password`
- `updated_at`

Rules:
- `content_digest` is computed from semantic provisioning content, not transport metadata.
- channel ordering must not affect the digest.
- generation is monotonic and independent from message/event/thing business IDs.

## Apply Algorithm On watchOS
When watch receives a standalone provisioning snapshot:

1. Validate protocol/schema version.
2. Compare `incoming.provisioning_generation` with locally persisted provisioning generation.
3. If `incoming <= local`, ignore the snapshot without mutating runtime state.
4. If `incoming > local`, apply the snapshot in one transaction:
   - save normalized `serverConfig`
   - save `notificationKeyMaterial` as part of persisted server config
   - upsert all incoming channel rows
   - soft-delete or remove all previously stored channels absent from the incoming snapshot
   - save provisioning metadata record with generation and digest
5. Reload in-memory presentation state from the local store if the UI needs refreshed observable values.
6. Start or refresh standalone networking infrastructure using the newly persisted local state.
7. Publish provisioning `ack`.

If any step before commit fails:
- do not partially advance provisioning generation
- do not publish success `ack`
- publish `nack` with failure stage and leave the previously applied local snapshot active

## Read Rules On watchOS

### Allowed Read Sources
The following runtime paths must read only from local persisted state:
- notification decryption
- standalone push handling
- wakeup pull
- subscription sync
- startup restore after process death
- cold-launch recovery

### Forbidden Read Patterns
The following patterns are prohibited:
- if decrypt fails, request provisioning from iPhone inline
- if channel password missing, attempt live pull from iPhone before failing
- combine `AppEnvironment.channelSubscriptions` with separate credential lookups to synthesize effective provisioning
- use watch-connectivity manifest state as a runtime config source

Manifest state is transport control state only. It is not business/runtime provisioning state.

## Mode Semantics

### Mirror Mode
- watch may keep the last applied standalone provisioning snapshot in local storage.
- mirror mode does not consume that state for mirrored message rendering.
- switching back to mirror mode does not require immediate deletion of locally persisted provisioning unless product/privacy policy explicitly requires it.
- mode switch success itself is defined by the watch mode-control acknowledgement contract in [/Users/ethan/Repo/PushGo/pushgo/docs/watch-mode-control-design.md](/Users/ethan/Repo/PushGo/pushgo/docs/watch-mode-control-design.md), not by provisioning mutation.
- switching back to mirror mode must not clear local business data, provisioning metadata, or durable channel credentials as a side effect of the mode flip itself.
- once watch confirms `effectiveMode = mirror`, iPhone may immediately resume mirror sync.

### Standalone Mode
- standalone mode consumes only the last successfully applied local provisioning snapshot.
- when standalone mode becomes active, startup and network bootstrap must use persisted local provisioning, not pending transport state.
- switching into standalone may trigger runtime reconcile, but that runtime reconcile is downstream of effective-mode apply. It must not redefine whether mode switch itself succeeded.
- switching into standalone must reuse the same shared local data and provisioning store; it changes runtime ownership, not storage shape.
- until watch reports `standaloneReady = true`, iPhone must continue mirror sync.
- switching into standalone therefore allows a temporary dual-ingress period; watch local dedupe must absorb duplicates from mirror plus standalone paths.

## Sync Triggers
iPhone should publish a new full provisioning snapshot when:
- watch enters standalone mode
- watch reconnects and iPhone detects standalone mode is active
- `serverConfig` changes
- `notificationKeyMaterial` changes
- channel subscription set changes
- any channel password changes

watch should not invent extra fetches from runtime failures.

Allowed transport-driven recovery:
- on stale or missing provisioning `ack`, iPhone deterministically republishes the latest snapshot
- on transport reconnect, iPhone may replay the latest manifest/package
- if iPhone observes watch effective mode drift after reconnect, iPhone may replay the latest target mode command under the bounded mode-control rules in [/Users/ethan/Repo/PushGo/pushgo/docs/watch-mode-control-design.md](/Users/ethan/Repo/PushGo/pushgo/docs/watch-mode-control-design.md)

Disallowed runtime-driven recovery:
- decrypt failure asks iPhone for config
- push handling failure asks iPhone for channel password
- foreground view open asks iPhone to refresh provisioning synchronously

## Relationship To Watch Connectivity
This design simplifies watch connectivity responsibilities:
- `WCSession` transport only advertises and delivers the latest provisioning snapshot
- watch-connectivity runtime only decides whether a snapshot has been delivered/applied/acked
- business/runtime code never depends on direct transport state after apply

In other words:
- transport owns delivery
- local DB owns runtime reads

That separation is the main complexity reduction.

It also means ordinary mode switching must not be encoded as storage deletion. Runtime ownership may change, but the shared local stores remain intact across both modes.

It also means mirror shutdown must not be tied only to mode apply. Mirror may stop only after watch reports `standaloneReady = true`.

## Required Refactor Boundaries

### On iPhone
- provisioning export must be built from persisted channel subscription state, not mixed in-memory state
- provisioning export must always be a full snapshot
- `ack` tracking must compare generation and digest only
- mirror sync policy must be driven by `targetMode` plus watch-reported `standaloneReady`, not by `effectiveMode` alone

### On watchOS
- `applyStandaloneProvisioningFromPhone` becomes the only place allowed to mutate persisted provisioning state from phone sync
- runtime decryption/pull/subscription code must depend on persisted state loaders only
- any branch that attempts runtime fallback to iPhone provisioning must be removed

## Migration Strategy

### Phase 1: Contract Freeze
- land this document
- update watch connectivity architecture doc to reference local-store-first provisioning
- update test matrix with runtime read-source assertions

### Phase 2: Storage Normalization
- add explicit provisioning metadata record on watch
- make watch runtime loaders read from persisted provisioning state only
- stop using manifest/runtime transport files as indirect config state

### Phase 3: Apply Path Hardening
- make watch standalone apply transactional
- advance provisioning generation only after successful commit
- `ack` only after commit

### Phase 4: Runtime Cleanup
- remove decrypt-failure and push-failure fallback branches that attempt live recovery from iPhone
- remove mixed-source provisioning assembly

### Phase 5: End-to-End Validation
- paired simulator regression
- reconnect / process restart / mode switch
- stale snapshot rejection
- decrypt with old key then new key after provisioning update

## Test Matrix Additions
The following scenarios must become mandatory:

1. Cold-launch watch in standalone mode:
   - no phone round-trip required
   - decryption and pull use locally stored provisioning

2. Standalone snapshot v10 already applied, v9 arrives later:
   - watch rejects v9
   - local DB remains on v10

3. Standalone snapshot removes one channel:
   - removed channel no longer exists in local DB after apply

4. Decrypt fails because local key is stale:
   - watch reports failure locally
   - watch does not trigger provisioning fetch from iPhone
   - next normal provisioning sync can repair the problem

5. iPhone reconnect replay:
   - if watch already has the latest generation, replay does not mutate local provisioning

6. Process restart after successful provisioning:
   - watch restores standalone behavior entirely from local DB

## Risks And Tradeoffs

### Benefits
- much simpler read/write model
- fewer races between memory state and persisted state
- lower coupling between business runtime and transport runtime
- easier simulator and real-device debugging

### Tradeoffs
- watch may temporarily continue using stale local provisioning until the next successful sync
- sync latency is handled by deterministic replay rather than runtime pullback

This tradeoff is intentional. It is preferable to hidden runtime recovery branches because it preserves predictable control flow.

## Non-Goals
- changing the product rule that iPhone owns provisioning inputs
- removing mirror/standalone dual mode
- making watch runtime depend on reachability
- teaching watch to edit provisioning values directly
