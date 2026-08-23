# Durable ingress v2 implementation

## Outcome

Implement the target architecture in `design/apple-durable-ingress-final-design.md`: one App Group durable ingress journal, durable/fenced ACK and pull work, idempotent canonical drain, database-observed UI, ingress-first startup, and opportunistic background acceleration.

## Acceptance

- Notification display does not await Gateway ACK or derived projections.
- Gateway ACK requires a committed validated payload or deterministic-discard tombstone.
- v2 pages cannot advance before local classification/materialization and the current ACK barrier.
- Direct invalid/corrupt/unknown-newer input is never ACKed.
- Full Gateway URL/device/delivery/contract identity is preserved; stale leases cannot settle.
- Canonical commit is the UI visibility boundary; projections retry independently.
- Foreground reconciliation is sufficient when background execution never runs.
- Legacy inbox/ACK/claim state imports idempotently and no new normal-path legacy writes remain after cutover.

## Outcome slices

1. Raw shared SQLite journal, migrations, identities, leases, cleanup, and legacy import.
2. NSE critical-path rewrite and exactly-once completion.
3. Canonical drain/derived outbox/database observation and bootstrap ordering.
4. ACK/pull page barrier and iOS background coordinator.
5. concurrency, process-kill, compatibility, real-target build and lifecycle verification.

## Evidence

Focused state-machine tests precede Swift package and app/NSE builds. Simulator evidence does not substitute for physical NSE/BGTask/force-quit checks, which remain explicit when unavailable.
