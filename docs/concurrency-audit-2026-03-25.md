# Concurrency Audit Report (2026-03-25)

## Scope
- Full Swift source scan in `pushgo/` for:
  - `@unchecked Sendable`
  - `nonisolated(unsafe)`
  - `@preconcurrency`
  - `Task.detached`
  - `MainActor.assumeIsolated`
  - `DispatchQueue.global(...)`
  - unsafe raw pointer / unmanaged bridging

## Summary
- Total matched items: 13
- `nonisolated(unsafe)`: 0
- `@unchecked Sendable`: 0
- `@preconcurrency`: present (ObjC / Apple framework bridge points)
- `Task.detached`: 0
- `MainActor.assumeIsolated`: 0
- unsafe raw pointer / unmanaged bridge: present only in C notify FFI signature declarations; unmanaged/pointer ownership logic removed from runtime

## Build verification snapshot
- `./scripts/apple_concurrency_gate.sh`: pass (strict build for macOS + watchOS + iOS, plus `swift test`).
- `./scripts/concurrency_audit.sh`: pass.

## High-priority remediation completed in this round
- Removed `@unchecked Sendable` from iOS `BackgroundExecutionLease` by making lease actor-isolated to main.
- Replaced one scheduler `Task.detached` with structured `Task` in private wakeup ack drain scheduler.
- Removed `@unchecked Sendable` from `LocalDataStore` persistence backend by actorizing `GRDBStore`.
- Removed `MainActor.assumeIsolated` singleton bridges from iOS/macOS/watchOS `AppEnvironment`.
- Replaced Darwin CF notification pointer callback bridge with notify dispatch registration, removing runtime `UnsafeMutableRawPointer`/`Unmanaged` ownership logic.
- Kept minimal `UnsafePointer` declarations only at C notify FFI boundary (allowlisted with explicit reason).
- Added enforceable audit/gate scripts and CI workflow.
- Added stale-allowlist detection in concurrency audit to prevent bypass residue.
- Upgraded concurrency audit to hard-fail on `@unchecked Sendable`, `MainActor.assumeIsolated`, `Task.detached`, and `DispatchQueue.global(...)`.

## Remaining tracked bridges
See `config/concurrency_allowlist.txt` for path-level reason and migration direction.
