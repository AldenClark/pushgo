# PushGo engineering rules

Repository-wide instructions for humans and coding agents:

- Treat a test as product evidence only when it exercises a reachable entry and asserts a user-visible, persisted, network, or platform result. File existence, version strings, accessibility identifiers, Automation State, and successful launch are supporting diagnostics, never sufficient oracles.
- Before changing behavior, identify the affected row in `docs/quality/capability-coverage.md`. Add or strengthen the smallest test that would fail if the intended user outcome were broken.
- During implementation run focused tests. Before handoff run `scripts/quality_test.sh pr` for product changes. Documentation-only or CI-only changes may run syntax/static checks instead, with the skipped product lane reported as `NOT RUN`.
- UI changes must cover the meaningful loading/content/empty/error/retry states affected by the change. Data changes must verify accurate values and relaunch persistence where persistence is part of the contract.
- Performance-sensitive changes require correctness evidence plus a measured milestone in nightly/release scope. Never use a sleep duration, file marker, or process lifetime as a performance proxy.
- Do not construct device × locale × state × fault Cartesian products. Prioritize frequent core journeys, prior incidents, data-loss/corruption risks, irreversible actions, and release boundaries. Cover equivalent long tails below the UI layer or document them as deferred.
- A retry may classify and recover infrastructure failures only. Never retry a product assertion until it turns green.
- Report `PASSED`, `FAILED`, `FLAKY`, `BLOCKED`, and `NOT RUN` distinctly. Do not claim physical-device, APNs, permission, background, or system-surface coverage from Simulator evidence.
- Update the capability index and the workstream progress record whenever capability scope or fresh evidence changes.

The implementation authority is `design/workstreams/pushgo-quality-testing-overhaul/ai-development-policy.md`.
