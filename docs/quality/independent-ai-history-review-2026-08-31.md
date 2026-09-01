# 2026-08-31 cross-platform independent AI history review

> Historical snapshot: this document records the blind/reveal review at the time it ran. Current closure and evidence boundaries are maintained in `completion-gate-ledger.md`, `capability-coverage.md`, and the workstream progress log; later fixes must not rewrite these historical findings into retroactive passes.

## Evidence boundary

Four reviewers were split into Apple A/B and Android A/B. Each received only five task prompts plus a newly materialized parent snapshot without `.git`, target commit, task corpus, semantic answer, evaluation document or prior review. They wrote purpose, forbidden states, caller-to-platform chain, credible counterexamples, minimum purpose-level Oracles, focused and delivery lanes, and six-state boundaries before any reveal. All twenty runtime states stayed `NOT RUN`; no score or pass rate was produced.

After all blind reports were complete, two separate reveal reviews compared them with the hidden corpus, target diff and current owners. The detailed build artifacts are:

- Apple blind: `build/quality-results/independent-ai-history-reviews/apple-a.md`, `apple-b.md`
- Apple reveal: `build/quality-results/independent-ai-history-reviews/apple-reveal.md`
- Android blind: `../pushgo-android/build/quality-results/independent-ai-history-reviews/android-a.md`, `android-b.md`
- Android reveal: `../pushgo-android/build/quality-results/independent-ai-history-reviews/android-reveal.md`

Those artifacts are review evidence, not product receipts. This file persists the decisions that affect policy, selection, product gaps and future regression work.

## Apple reveal decisions

| Historical task | Independent semantic result | Target behavior/evidence boundary | Attribution and action |
| --- | --- | --- | --- |
| Gateway validate before commit | Recovered candidate-first registration, fresh identity, failure non-commit, Sheet ownership and relaunch. | Target diff implements the core order and purpose-level UI/Core Oracles. | Accept core result. Keep remote orphan cleanup as optional strengthening unless the product contract makes it required. |
| Channel rejection compensation | Recovered remote rejection, created=true local-fault compensation, canonical ID, Sheet-only error and retry. | Target covers the declared provider/new-channel branch and relaunch. | Accept core result. Do not inflate minimum scope with a durable compensation-failure ledger without a product requirement. |
| Encrypted corruption safe failure | Recovered fail-closed, wrong-key correction, corrupt relaunch and malicious companion-field counterexample. | Target corrupt fixture uses already-safe companion text, so it does not kill the strongest untrusted-title/body false green. | `testability`; retain an explicit malicious companion-field negative control. |
| Thing projection relations | Recovered three real relations/details, return ownership and stale-head rejection. | Target combines UI relation journeys with a Store stale-head control, but not one single stale-head-plus-reopen sample. | Core behavior accepted; combination remains a targeted strengthening, not a broad matrix. |
| Message refresh recovery | Recovered Provider failure honesty, old-snapshot retention, same-action retry, exact new detail and persistence. | Target success journey relaunches; fail-once recovery does not relaunch in that same method. | `testability`; current fixed core selector covers refresh, but do not rewrite history as a fully combined receipt. |
| Large text/localization | Recovered actual zh-Hans/accessibility5 state, real controls, exact results and environment restore. | Target runner and UI method implement those boundaries. | Accept. The dedicated lane must still be recorded as aggregated by Nightly. |
| Purpose-level performance | Recovered cold-to-accurate-sentinel timing, exact real-tap detail and Simulator/physical separation. | Simulator purpose gate is strong; physical runner does not machine-prove the reference device has the declared 1k dataset. | `environment + testability`; physical remains owner-paused `NOT RUN`. |
| macOS status-item recovery | Recovered real status-item close/minimize/repeat, unique usable key window. | Historical target E2E covered close more strongly than minimize/repeat; current suite later closed the lifecycle and size journeys. | Historical gap preserved; current fresh receipts are recorded separately in the P1 ledger. |
| Watch core journeys | Recovered readiness, three real domains, exact details, cancel/delete/relaunch and local error ownership. | Target implements the Simulator journey and honest BLOCKED boundary. | Accept Simulator scope; physical Watch remains owner-paused `NOT RUN`. |
| iOS system notification route | Recovered real system card/tap, exact detail, read persistence, relaunch and readiness separation. | Target implements the Simulator system-surface chain without direct-open/mark-read shortcuts. | Accept Simulator scope; APNs/physical delivery remains owner-paused `NOT RUN`. |

Apple blind reasoning consistently found the business purpose and false-green counterexample. Its recurring weakness was proposing optional long-tail matrices as minimum acceptance and inferring `nightly`/`pr` where the hidden corpus required `release`. The policy correction is to separate minimum Oracle from optional strengthening and to provide governance inputs rather than asking the model to guess them.

## Android reveal decisions

| Historical task | Independent semantic result | Target/current behavior boundary | Attribution and action |
| --- | --- | --- | --- |
| Sheet ownership + Gateway validation | Recovered Sheet exclusivity and validate/register-before-commit. | Candidate rejection seam fires before real registration; multi-store rollback omits some ACK/remote compensation boundaries. | `product + testability`; keep partial and add real registration-failure/rollback endpoint evidence. |
| Channel remote compensation | Recovered rejection, created ownership, compensation and unique retry result. | Provider created=true branch is credible; created=false ownership and Private create compensation remain unresolved. | `product + testability`; require protocol ownership before adding more UI variants. |
| Encrypted corruption recovery | Recovered the exact high-risk flaw: untrusted fallback may display/notify/ACK after authentication failure. | Historical tests used a safe fallback and bypassed processor/notification/ACK, so the central false green survived. The current worktree now carries trust disposition from parser through persistence/notification/Provider/Private/Legacy boundaries, strips unauthenticated companion and reserved recovery fields, rejects unauthenticated Entity projection, and preserves authentic inline ciphertext for later key correction. | `product + testability`; source/JVM repair is independently reviewed and the clean full JVM suite passes 274/274, but emulator UI, system notification surfaces, Room-ledger lifecycle and real provider/ACK execution remain `NOT RUN`. |
| Thing relation journey | Recovered accurate relations/details, cross-Thing isolation and real repository/container recreation. | Initial journey is credible; relaunch rechecks only a subset and may reseed. | `testability`; add one no-reseed container recreation, not a relation matrix. |
| Message refresh recovery | Recovered Provider-to-Paging completion, honest failure and same-action retry. | Pull errors are visible, but refresh state ends before the target Paging generation/new stable ID is known visible. | `product + testability`; completion must bind to the visible canonical result. |
| Large-font localized task | Recovered actual zh-CN/1.5, Sheet-owned error-to-correction, unique result and relaunch. | Historical test covers localized large-font success only; no error recovery or relaunch. | `corpus + testability`; recorded evidence was too broad and must be corrected or completed. |
| Purpose-level Android performance | Recovered 1k correctness, real detail, valid metrics, Baseline Profile and emulator/physical separation. | Strong harness exists; visible total/representative set and Profile Require execution are not fully proven. | `testability + environment`; physical remains owner-paused `NOT RUN`. |
| Transactional transport switch | Recovered old-route-until-commit, rollback and unique active-route semantics. | Existing “prepare” already mutates remote channel type/retires old provider before local commit. | `product`; needs protocol/durable-saga design, not more selector UI checks. |
| Protected settings write failure | Recovered typed secure-write failure, old-state preservation, Sheet retry and relaunch. | Core propagation and selected compensation are credible; delete/rollback-failure and complete multi-resource transaction remain open. | `product + testability`; keep scope explicit and do not claim all protected settings atomic. |
| Android system notification route | Recovered Worker-to-system-card-to-exact-detail/read/restart and cross-notification identity. | Local system journey is strong; final relaunch is Activity-level and lacks a distinct-message PendingIntent collision control. | `testability + environment`; add process/container boundary locally, keep FCM/physical paused. |

Android blind reasoning found the important product problems more reliably than the recorded semantic answer. This is the clearest proof that recorded `semantic_review` must remain a challengeable hypothesis, not an answer key.

## Test-system corrections

1. Blind packets expose the semantic inputs `task_prompt`, `user_outcome` and `credible_counterexample`, plus only the operational fields `id`, `required_response` and `materialize_command`. Base/target commits, `minimum_lane`, `required_capabilities`, `required_changed_path_groups`, target bytes and semantic answers remain in the reveal rubric because gate 10 must test whether AI derives them.
2. Review output must separate a fast focused command from the minimum delivery lane. If governance data is unavailable, selector status is `INDETERMINATE`, not a guess.
3. Reveal compares target diff to the real production owner and the counterexample-killing Oracle. A recorded evidence string cannot validate itself.
4. “Relaunch” is no longer sufficient wording by itself; tasks must say Activity, container/Store, process, force-stop or device reboot.
5. Minimum acceptance and optional strengthening are separate. Optional cross-product matrices cannot silently become current blockers.
6. No aggregate score is permitted. One missed high-risk purpose remains visible and cannot be averaged away.

## Current gate interpretation

- Independent blind design/reveal is complete for the twenty sampled tasks and removes the prior same-context-only common-mode limitation.
- The sample does **not** prove that AI can implement and execute every task correctly: reviewers designed tests but did not edit targets or run native lanes. Completion gate 10 therefore remains `PARTIAL`.
- Reviewer packet leakage is repaired in both repositories: packets include the user outcome/counterexample but omit base/target commit identity and hidden selection answers; exact-key tests prevent governance/semantic-answer leakage, and both 10-task replays return `READY_FOR_RECORDED_SEMANTIC_REVIEW`. A future independent execution must consume the corrected packet; the completed first review is not retroactively rewritten.
- The reveal found unexplained product/test gaps in Android encryption, transport switching and refresh completion. Encryption is now repaired and independently challenged at source/JVM level (clean full JVM 274/274), including malicious companion, authenticated-null, forged recovery-field, inline recovery and Entity fail-closed controls; emulator/system/provider/ledger execution remains `NOT RUN`. Refresh and transport remain open, so completion gates 6, 10 and 11 cannot be promoted.
