# Watch Connectivity Architecture

## Goal
PushGo now treats Apple Watch connectivity as a single subsystem instead of letting UI, app bootstrap, and sync jobs talk to `WCSession` directly.

This document only defines watch transport and state-machine behavior. Canonical message/event/thing classification and identity rules come from [/Users/ethan/Repo/PushGo/docs/inbound-payload-semantic-contract-v1.md](/Users/ethan/Repo/PushGo/docs/inbound-payload-semantic-contract-v1.md).

watch standalone provisioning storage and runtime read rules are defined in [/Users/ethan/Repo/PushGo/pushgo/docs/watch-provisioning-local-store-design.md](/Users/ethan/Repo/PushGo/pushgo/docs/watch-provisioning-local-store-design.md). This transport document must stay consistent with that local-store-first design.

watch desired/effective mode convergence and confirmation rules are defined in [/Users/ethan/Repo/PushGo/pushgo/docs/watch-mode-control-design.md](/Users/ethan/Repo/PushGo/pushgo/docs/watch-mode-control-design.md). This transport document must stay consistent with that control-plane design.

## Core Rules
- `WatchConnectivityCoordinator` is the only type allowed to own `WCSession`.
- `WatchConnectivityRuntime` persists manifest state, outbox files, processed event IDs, and pending reliable events under `Application Support/watch-connectivity-v3/`.
- UI and business code consume cached `WatchLinkState`; they do not read `WCSession.activationState`, `isPaired`, `isWatchAppInstalled`, or `isReachable` directly.
- Schema upgrades are destructive by design. A new schema version forces both sides back to mirror mode and clears stale watch-sync state.
- Mirror and standalone package application must both close with an explicit apply `ack` or `nack`; file transfer completion alone is not treated as semantic success.

## Transport Split

### `applicationContext`
- Carries only `WatchSyncManifest`.
- Contains protocol version, active mode, control generation, latest mirror package ref, latest standalone package ref, explicit mirror/standalone apply acknowledgements, optional standalone readiness status, and optional inline state packages when they fit under the context safety limit.
- Also carries mode-control latest-state information. iPhone advertises `targetMode`; watch publishes the latest `effectiveMode` confirmation and latest `standaloneReady` truth.
- Latest-state semantics only. It must stay small and property-list safe.
- Publishing a manifest advertises desired state. It does not prove the receiver has applied the corresponding package unless the peer later publishes an updated manifest with the corresponding apply cursor.
- Publishing a control manifest also does not prove watch has switched mode. Mode switch confirmation requires a watch reply carrying explicit effective-mode acknowledgement for the corresponding control generation.
- Publishing standalone readiness does not prove the switch modal should still be open. Readiness is a later background-convergence state.
- Small mirror snapshots may be embedded directly in the manifest so the watch can apply them without waiting for `transferFile` or `transferUserInfo`.
- watchOS also publishes a reply manifest after a successful mirror or standalone apply. The reply manifest carries explicit `mirrorSnapshotAck` / `standaloneProvisioningAck` records, which are the primary semantic success signals.
- watchOS must also publish reply manifests when bootstrap, reconnect, or forced migration changes the latest effective-mode truth. iPhone cannot infer effective mode only from its own target state.
- watchOS should also publish reply manifests when standalone readiness changes, or when reconnect/bootstrap needs to replay the latest readiness truth to iPhone.

### `transferFile`
- Carries large snapshots and provisioning payloads.
- iPhone uses it for `MirrorSnapshotPackage` and `StandaloneProvisioningPackage`.
- Outbox files remain on disk until `didFinish fileTransfer` or explicit cancellation, which avoids the previous ENOENT storms.
- The receiver copies the incoming file into a staging directory before decoding.
- Every package must carry:
  - `packageID`
  - `generation`
  - `contentDigest`
  - `kind`

### `transferUserInfo`
- Carries reliable ordered events.
- Current event kinds:
  - `mirrorActionBatch`
  - `mirrorActionAck`
  - `mirrorSnapshotInline`
  - `mirrorSnapshotNack`
  - `pushTokenUpdate`
  - `standaloneProvisioningInline`
  - `standaloneProvisioningAck`
  - `standaloneProvisioningNack`
- Every event has a stable `eventID` and schema version. The runtime deduplicates incoming IDs and persists pending outbound events until the session accepts them.
- Small snapshot/provisioning packages may also be sent as reliable inline fallback events. They use the same generation and digest as the `transferFile` package, so apply guards remain identical across transports.
- Mirror snapshot success no longer depends on a reliable event ack. The canonical success path is now the watch reply manifest `mirrorSnapshotAck`.
- `standaloneProvisioningAck` remains accepted for backward compatibility, but new semantic success is the watch reply manifest `standaloneProvisioningAck`.

### `sendMessage`
- Carries only foreground acceleration hints.
- Current live message kinds:
  - `requestLatestManifest`
  - `refreshHint`
- No business-critical delivery depends on reachability.

## Mode Flows

### Mirror Mode
1. iPhone updates local message/event/thing state.
2. iPhone rebuilds a mirror snapshot package and updates the manifest.
3. If the package is small enough, iPhone embeds it directly in the manifest. It also queues the package with `transferFile` and can still send a `refreshHint` when reachable.
4. watchOS applies the inline snapshot immediately when present; otherwise it stages the file and decodes from `transferFile`.
5. After apply succeeds, watchOS publishes a reply manifest whose `mirrorSnapshotAck.generation` matches the applied mirror snapshot generation and whose digest matches the applied package.
6. iPhone treats that reply-manifest cursor as the semantic success signal for mirror mode and cancels retry for matching or newer generations.
7. Missing or stale mirror apply acknowledgement must trigger deterministic resend of the current mirror package. If the package stays under the inline safety limit, iPhone also sends it as a reliable inline fallback event.
8. watchOS sends read/delete actions back as reliable events.
9. iPhone applies the actions, emits a reliable ack event, and the next mirror snapshot converges the UI.

### Standalone Mode
1. iPhone exports server config, notification key material, and channel credentials as a provisioning package.
2. iPhone publishes the manifest and transfers the package file.
3. watchOS decodes the provisioning package and commits it to local persistent provisioning state before reporting success.
4. On success, watchOS publishes a reply manifest whose `standaloneProvisioningAck` matches the committed generation and digest.
5. Missing or stale provisioning acknowledgement must trigger deterministic resend of the current provisioning package. If the package stays under the inline safety limit, iPhone also sends it as a reliable inline fallback event.
6. After apply, watchOS handles network traffic independently by reading provisioning only from its local persisted state.
7. Business/runtime failures such as decrypt failure must not trigger ad hoc provisioning fetches from iPhone. Recovery stays in the sync subsystem.
8. watchOS reports token changes and apply results back through reliable events.

### Mode Control
1. iPhone writes `targetMode` and emits a control manifest with a new `controlGeneration`.
2. watch compares the incoming target mode with current local effective mode.
3. If the mode already matches, watch must not re-run mode transition logic; it publishes a success acknowledgement with `noop = true`.
4. If the mode differs, watch applies the mode transition, persists the new effective mode, and publishes a success acknowledgement for that control generation.
5. If watch cannot apply the mode transition, it publishes a failure acknowledgement and keeps the previous effective mode.
6. iPhone must not declare settings-page modal success until it receives a matching success acknowledgement for the current pending control generation.
7. iPhone settings modal must not wait for `standaloneReady`; it waits only for mode apply or timeout.
8. If iPhone later receives watch status showing `effective != target`, it may replay the target control command with bounded retry and backoff.
9. If iPhone later receives watch status showing `target = standalone` but `standaloneReady = false`, it keeps mirror sync enabled while background convergence continues.
10. Once watch reports `standaloneReady = true`, iPhone may stop mirror sync.
11. When watch reports `effectiveMode = mirror`, iPhone immediately re-enables mirror sync.
12. Reconnect and bootstrap status reports are part of the same latest-state mode-control contract; they are not optional diagnostics.

## Upgrade and Cleanup Policy
- `WatchConnectivitySchema.currentVersion` is the source of truth for protocol compatibility.
- When the runtime detects an older on-disk schema, it deletes the old runtime directory, marks `pendingForcedReconfigure`, and waits for the app to consume that flag.
- iPhone reset behavior:
  - reset watch mode to `mirror`
  - zero local watch generations
  - cancel pending sync jobs
- watchOS reset behavior:
  - reset watch mode to `mirror`
  - zero local watch generations
  - keep shared local business data and provisioning state unless schema migration explicitly invalidates them
  - delete pending mirror actions
  - tear down standalone runtime activity

## Maintenance Constraints
- New watch payloads must declare their transport class before implementation.
- Large payloads must use `transferFile`.
- Reliable background events must use `transferUserInfo`.
- `sendMessage` remains best-effort only.
- Any future watch status UI must bind to `WatchLinkState`, not raw `WCSession` properties.
- watch light payload derivation must obey the shared inbound semantic contract; `delivery_id` is never an acceptable fallback for `message_id`.
- Any future watch mode UI on iPhone must distinguish `targetMode` from `effectiveMode`; local target state alone is not sufficient success evidence.
- Mirror sync shutdown must be gated by watch-reported `standaloneReady`, not merely by `effectiveMode = standalone`.
- Ordinary mode switching must not be implemented as destructive cleanup of watch local business data or provisioning state.
