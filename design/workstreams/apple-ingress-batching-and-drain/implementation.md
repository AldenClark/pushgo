# Apple ingress batching and drain hardening

## Outcome

Fix notification replay read-state regression now, and define the safe implementation boundary for page batching plus fenced single-flight drain without regressing the durable-ingress/ACK architecture.

## Scope

1. Preserve local read state when a duplicate notification request refreshes canonical content.
2. Audit the full provider page, journal, canonical store, derived work, counts, and UI observation path.
3. Audit all inbox/network merge entry points and existing lease/state-machine behavior.
4. Freeze the P1 design and verification oracles before changing those concurrency and transaction boundaries.

## Acceptance

- Duplicate notification replay cannot change a read row back to unread.
- The P0 failure path has a focused regression test and the affected/full package suites pass.
- P1 design is grounded in the 2026-08 durable-ingress architecture and current implementation, including explicit rejected alternatives and rollback behavior.
- No P1 code is merged before batch outcome, lease fencing, page barrier, refresh coalescing, and fault-injection tests are ready.

## Design authority

- `design/apple-durable-ingress-final-design.md`
- `design/apple-ingress-batching-and-drain-final-design.md`
