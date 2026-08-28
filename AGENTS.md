# PushGo engineering rules

Repository-wide instructions for humans and coding agents:

- Treat a test as product evidence only when it exercises a reachable entry and asserts a user-visible, persisted, network, or platform result. File existence, version strings, accessibility identifiers, Automation State, and successful launch are supporting diagnostics, never sufficient oracles.
- Before changing behavior, identify the affected row in `docs/quality/capability-coverage.md`. Add or strengthen the smallest test that would fail if the intended user outcome were broken.
- After edits, run `scripts/quality_changed.sh` (or pass explicit `--base/--head`) to enforce the deterministic minimum lane. Treat its impact plan as a lower bound: still trace callers, state/data owners, errors, generated artifacts, and platform consumers. Never bypass an unmapped product path; map the real capability first.
- Changes to impact rules, test architecture, or AI testing policy must keep `config/quality-ai-task-history.json` at ten or more real tasks and pass `python3 scripts/quality_ai_history.py --check`. The replay proves selector/lane/co-change contracts only; use its blind packets for an isolated semantic review and never turn recorded prose into an automatic AI score.
- During implementation run focused tests. Before handoff run `scripts/quality_test.sh pr` for product changes. Documentation-only or CI-only changes may run syntax/static checks instead, with the skipped product lane reported as `NOT RUN`.
- UI changes must cover the meaningful loading/content/empty/error/retry states affected by the change. Data changes must verify accurate values and relaunch persistence where persistence is part of the contract.
- Localization-resource changes must pass `python3 scripts/verify_apple_localizations.py`. Changes that can affect text wrapping, control reachability, sheets, navigation, or accessibility semantics must run `scripts/quality_test.sh accessibility` when the representative iOS task is in scope; the resource contract and one real large-text task complement each other and neither alone proves the other.
- Performance-sensitive data changes require correctness evidence plus `scripts/quality_test.sh performance`; user-visible launch/frame/resource changes additionally require the applicable Release-like physical trace before that scope can pass. Never use a sleep duration, file marker, process lifetime, synthetic container, or Simulator timing as a proxy for physical performance.
- Do not construct device × locale × state × fault Cartesian products. Prioritize frequent core journeys, prior incidents, data-loss/corruption risks, irreversible actions, and release boundaries. Cover equivalent long tails below the UI layer or document them as deferred.
- A retry may classify and recover infrastructure failures only. Never retry a product assertion until it turns green.
- Report `PASSED`, `FAILED`, `FLAKY`, `BLOCKED`, and `NOT RUN` distinctly. Do not claim physical-device, APNs, permission, background, or system-surface coverage from Simulator evidence.
- Treat `build/quality-results/*-summary.json` as an execution receipt, never as whole-product coverage. `selected_claims` states intent; only `executed_claims` completed. Keep product and test-system status separate; a recovered runner remains `FLAKY`.
- Update the capability index and the workstream progress record whenever capability scope or fresh evidence changes.

The implementation authority is `design/workstreams/pushgo-quality-testing-overhaul/ai-development-policy.md`.
