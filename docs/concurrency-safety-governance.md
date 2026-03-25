# Concurrency Safety Governance (Swift 6)

This document defines the project-wide concurrency contract to keep Apple clients close to Rust-level discipline.

## 1) Isolation Domains Are Fixed
- UI/App lifecycle state is `@MainActor` only.
- Persistence, indexing, and transport are actor-owned (for example `LocalDataStore`, search indexes, pull/ack coordinators).
- Notification ingress uses one boundary: sanitize and normalize first, then dispatch to actor-owned services.

## 2) Non-Sendable Data Does Not Cross Boundaries
- `UNNotification*` and heterogeneous dictionaries (`[AnyHashable: Any]`) stay at ingress boundary.
- Cross-actor calls should carry typed DTOs and `Sendable` structures only.
- Temporary bridges must be documented in `config/concurrency_allowlist.txt` with explicit reason.

## 3) Build/Lint Gates Are Mandatory
- Compiler settings: strict concurrency + warnings as errors.
- Gate command: `./scripts/apple_concurrency_gate.sh`.
- Audit command: `./scripts/concurrency_audit.sh`.
- Audit allowlist must be minimal and exact: stale entries fail the audit.
- CI must run the gate on PRs and main branch.

## 4) Concurrency Design Review Checklist
For each new async workflow/API, review and record:
- Actor ownership of each mutable state.
- Whether every cross-boundary parameter/return type is `Sendable`.
- Cancellation and lifetime semantics.
- Failure policy (retry/backoff/block) and idempotency.
- Whether any bridge (`@preconcurrency`, `@unchecked Sendable`, `Task.detached`) is introduced; if yes, why and planned removal date.

## Disallowed by default
- `nonisolated(unsafe)`.
- `@unchecked Sendable`.
- `MainActor.assumeIsolated`.
- `Task.detached`.
- `DispatchQueue.global(...)`.
