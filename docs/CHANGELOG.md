# Changelog

## 2026-03-18
- Formalized the watch mode-control design around `desiredWatchMode` on iPhone and `effectiveWatchMode` on watch, including explicit mode acknowledgement, `noop` success semantics, and bounded replay after reconnect drift.
- Clarified that ordinary mirror/standalone mode switching is a runtime ownership change only: it must not clear shared local business data, provisioning state, or durable channel credentials.
- Expanded the watch connectivity test matrix to cover desired/effective convergence, bounded resend, reconnect status replay, and non-destructive mode switching.
- Refined the watch mode-control design so iPhone settings now represent `targetMode`, while watch separately reports `effectiveMode` and `standaloneReady`.
- Clarified that the iOS loading modal waits only for mode apply and has its own timeout; it must not block on final standalone runtime convergence.
- Added the no-loss transition rule: iPhone keeps mirror sync enabled until watch reports `standaloneReady = true`, and watch local dedupe absorbs temporary dual-path ingress during mode transitions.

## 2026-03-16
- Rebuilt Apple Watch connectivity around a single `WatchConnectivityCoordinator` and `WatchConnectivityRuntime`.
- Split transports by official semantics:
  - `applicationContext` for `WatchSyncManifest`
  - `transferFile` for mirror/provisioning packages
  - `transferUserInfo` for reliable events
  - `sendMessage` for foreground refresh hints only
- Removed direct `WCSession` reads from iOS/watchOS app entry layers and replaced them with cached `WatchLinkState`.
- Restored iOS settings behavior so the watch standalone row is hidden when no paired+installed watch companion is available.
- Added destructive schema migration for stale watch-connectivity runtime state; both sides now reset to mirror mode on protocol upgrade.

## 2026-03-17
- Froze a cross-stack inbound semantic contract for `message` / `event` / `thing` / `pure_wakeup` classification and canonical business IDs.
- Tightened watch connectivity semantics so mirror and standalone package application both require explicit apply `ack` / `nack` instead of treating file transfer completion as success.
- Added a proposed local-store-first watch provisioning design: iPhone remains the provisioning source of truth, while watch runtime reads only from its persisted local provisioning snapshot after apply.
- Added a proposed desired-mode versus effective-mode watch control design so iPhone settings success depends on explicit watch mode confirmation instead of immediate local optimism.
