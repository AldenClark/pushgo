# Watch Mode Control Design

## Status
- Proposed architecture.
- This document defines how iPhone `targetMode`, watch `effectiveMode`, and watch `standaloneReady` must converge.
- It does not change the existing product model:
  - iPhone is still the control-plane source of truth for watch mode intent.
  - watch still supports `mirror` and `standalone`.
  - watch runtime data and provisioning stay local and shared across both modes.

## Problem Statement
The current mode switch path still conflates three different truths:
- iPhone target mode
- watch effective mode
- watch standalone runtime readiness

That causes four product failures:
- settings UI can block on work that is slower and less deterministic than mode switching itself
- settings UI can report success before standalone runtime is actually able to receive independently
- mirror sync can stop too early during `mirror -> standalone`
- reconnect, background execution, or temporary disconnects can be misread as hard switch failure

## Core Decision
Watch mode control must use three explicit state axes:
- iPhone owns `targetMode`
- watch owns `effectiveMode`
- watch owns `standaloneReady`

These axes have different meanings:
- `targetMode` = user intent
- `effectiveMode` = watch runtime behavior currently applied
- `standaloneReady` = watch standalone receive path is ready enough that iPhone may stop mirror sync

Essential rules:
- iPhone settings toggles only `targetMode`
- mode-switch loading only waits for watch to apply `effectiveMode`
- loading does not wait for `standaloneReady`
- iPhone continues mirror sync until watch reports `standaloneReady = true`
- mode switching must not clear local message/event/thing data, provisioning state, or durable channel credentials

## State Model

### On iPhone
Persist and expose:
- `targetMode`
- `effectiveMode`
- `standaloneReady`
- `pendingControlGeneration`
- `lastConfirmedControlGeneration`
- `lastObservedReportedGeneration`
- `watchModeSwitchStatus`

Recommended `watchModeSwitchStatus` values:
- `idle`
- `switching`
- `confirmed`
- `timed_out`
- `failed`

### On watch
Persist and expose:
- `effectiveMode`
- `standaloneReady`
- `lastAppliedControlGeneration`
- `lastReportedControlGeneration`
- optional latest readiness signature for dedupe

watch already persists `watchMode`. Under this design that field remains the durable `effectiveMode`.

watch runtime status details such as token state, route state, and subscription state remain internal inputs into `standaloneReady`; they are not the user-facing mode state.

## Protocol Contract

### 1. Target Mode Command
iPhone publishes target mode using the control manifest:
- `targetMode`
- `controlGeneration`

The control manifest remains a desired-state advertisement. It is not proof that watch has fully converged.

### 2. Effective Mode Acknowledgement
watch must reply with an explicit mode acknowledgement carrying:
- `effectiveMode`
- `sourceControlGeneration`
- `appliedAt`
- `noop`
- `status`
- optional `failureReason`

Recommended `status` values:
- `applied`
- `failed`

The essential rule is:
- `applied` means watch has committed the new `effectiveMode` locally and triggered any required runtime transition
- `applied` does not mean that standalone runtime has fully converged

### 3. Standalone Readiness Status
watch must separately publish whether standalone receive capability is ready.

Minimum fields:
- `effectiveMode`
- `standaloneReady`
- `sourceControlGeneration`
- `provisioningGeneration`
- `reportedAt`
- optional `failureReason`

This status is latest-state control information, not a business event stream.

## Success Semantics

### Settings Modal Success
iPhone may close the mode-switch loading modal successfully only when:
- `ack.sourceControlGeneration == pendingControlGeneration`
- `ack.effectiveMode == targetMode`
- `ack.status == applied`

That means:
- watch has accepted the switch
- watch has applied the mode locally
- watch has started operating under the new runtime behavior

It does not mean standalone runtime is fully ready.

### Settings Modal Timeout
The loading modal must have a bounded timeout.

Timeout means only:
- watch did not confirm mode application quickly enough for the current foreground interaction

Timeout does not mean:
- mode switch has permanently failed
- standalone runtime can never converge
- iPhone should destructively roll back state

Recommended timeout behavior:
- dismiss loading with a non-destructive timeout result
- keep `targetMode` unchanged
- continue background convergence
- keep mirror sync enabled until `standaloneReady == true`

### Standalone Readiness Success
`standaloneReady = true` means watch is ready for iPhone to stop mirror sync.

It is separate from modal success.

## Standalone Ready Definition
watch may publish `standaloneReady = true` only when all of the following are true:
- `effectiveMode == standalone`
- provisioning has been applied and persisted locally
- push authorization is available
- APNS token exists locally
- provider route for the current token/config exists
- channel subscriptions for the current provisioning snapshot have been reconciled successfully
- no known blocking runtime error is active

If any prerequisite becomes false, watch must publish `standaloneReady = false`.

## Mirror Sync Gating Rules
These rules are mandatory:
- if `targetMode == mirror`, iPhone keeps mirror sync enabled
- if `targetMode == standalone` and `standaloneReady == false`, iPhone still keeps mirror sync enabled
- if `targetMode == standalone` and `standaloneReady == true`, iPhone may stop mirror sync
- when switching from `standalone -> mirror`, once watch confirms `effectiveMode == mirror`, iPhone immediately re-enables mirror sync

This is the primary no-loss switching rule.

## Noop Semantics
watch must compare incoming target mode against current local effective mode.

If both are equal:
- do not trigger runtime teardown or rebuild
- do not re-run mode transition logic
- update `lastAppliedControlGeneration`
- immediately return success ack with `noop = true`

This prevents repeated control replay from perturbing an already-correct watch runtime.

## Replay / Drift Recovery

### iPhone-Initiated Replay
If iPhone receives watch status showing:
- `effectiveMode != targetMode`

then iPhone may replay the latest target-mode command, but only under controlled conditions:
- the reported `sourceControlGeneration` is older than the pending control generation, or
- the pending generation has timed out without confirmation, or
- reconnect/bootstrap proves watch is still advertising older mode-control state

Replay rules:
- bounded retries only
- stepped or exponential backoff
- stop retrying after a small fixed limit
- transition to `timed_out` or `failed` only for the foreground modal / user-visible switch interaction
- background convergence may continue later when connectivity resumes
- replay never automatically disables mirror sync while `standaloneReady == false`

### watch-Initiated Status Sync
watch should proactively publish `effectiveMode` and `standaloneReady` when:
- bootstrap completes
- a control command is applied
- standalone readiness changes
- provisioning apply changes readiness inputs
- push authorization changes
- APNS token availability changes
- route or subscription reconcile changes readiness
- WCSession reconnects
- iPhone requests latest manifest/state

Status publication should be edge-triggered by signature change, not periodic heartbeat.

## Transport Recommendation
Mode acknowledgement and standalone readiness should ride the latest-state control plane as manifest data, not ordered business events.

Why:
- both are latest-state control information
- both must survive reconnect and process restart
- iPhone needs the newest truth, not an ordered queue history

Reliable event fallback remains acceptable only for compatibility or small inline package fallback, not as the primary truth for mode state.

## UI Contract

### iPhone Settings
When user toggles watch mode:
1. update `targetMode`
2. send control manifest with new `controlGeneration`
3. present a loading modal
4. wait only for matching watch mode acknowledgement
5. close modal on `applied` or `noop`
6. if timeout occurs, dismiss with a soft timeout result and continue background convergence

The loading modal must not wait for `standaloneReady`.

### iPhone Display Rules
The settings page should render:
- target mode
- effective mode
- standalone readiness summary when target mode is standalone

Suggested user-facing states:
- switching to mirror
- switching to standalone
- standalone preparation in progress
- standalone ready
- switch confirmation timed out

`standalone preparation in progress` means watch has accepted standalone mode but has not yet reported `standaloneReady = true`.

### watch UI
watch local UI should display only `effectiveMode`, because that is the actual applied runtime mode.

watch should not display iPhone target mode as if it were already active.

## Interaction With Local-Store-First Provisioning
This document does not change provisioning ownership rules.

Mode and readiness semantics remain:
- business data store is shared
- provisioning store is shared
- only runtime behavior changes

Therefore:
- switching to `mirror` tears down standalone runtime activity but keeps local provisioning and local business data
- switching to `standalone` starts standalone runtime using already persisted local provisioning
- switching either direction must preserve the durable channel credential set
- mirror/standalone switching may allow temporary dual-path message ingress; watch local dedupe must absorb duplicates

## Runtime Ownership Rules

### In Mirror Mode
- watch keeps local business data and local provisioning state intact
- watch stops owning direct gateway route and subscription lifecycle
- iPhone mirror sync is enabled

### In Standalone Mode Before Ready
- watch owns `effectiveMode = standalone`
- watch is still converging standalone runtime in background
- iPhone mirror sync remains enabled

### In Standalone Mode After Ready
- watch owns direct gateway route and subscription lifecycle
- watch uses only persisted local provisioning state and durable channel credentials
- iPhone may stop mirror sync

### On Mode Change
- mode change only changes runtime ownership and reconciliation behavior
- mode change must not be implemented as destructive data cleanup
- temporary duplicate ingress during transition is acceptable and expected
- duplicate elimination is the responsibility of the shared watch local dedupe rules

## Failure Handling

### iPhone Side
If watch mode ack reports:
- `status = failed`

then iPhone should:
- keep `targetMode` unchanged
- mark switch status failed
- preserve the last confirmed `effectiveMode`
- keep mirror sync policy driven by `targetMode` and `standaloneReady`

If the loading modal times out:
- mark the foreground interaction as timed out
- do not destructively roll back `targetMode`
- do not stop mirror sync early
- continue background convergence when connectivity returns

### watch Side
If watch cannot apply a control command:
- local effective mode remains unchanged
- it must report `failed`
- it must not claim success and defer failure into hidden runtime state

If standalone runtime is not ready after mode apply:
- watch still reports mode `applied`
- watch separately reports `standaloneReady = false`
- watch does not pretend mode apply failed just because downstream readiness is still converging

## Required Refactor Boundaries

### iPhone
- rename conceptual desired mode to `targetMode` in state and UI semantics
- stop treating loading-modal success as equivalent to standalone runtime readiness
- keep mirror sync enabled until watch reports `standaloneReady = true`
- consume watch-reported `effectiveMode` and `standaloneReady` as real state
- replay only control commands, not data sync, when recovering mode drift

### watch
- publish explicit `effectiveMode` acknowledgement and separate `standaloneReady` state
- make readiness computation derive from persisted provisioning plus runtime reconcile results
- never rerun mode transition on same-mode replay; return `noop` success instead
- allow temporary dual-path ingress and rely on shared local dedupe instead of destructive cutover

## Robustness Constraints
The design must remain correct when:
- watch is away from iPhone but still online
- watch is away from iPhone and temporarily offline
- watch process is backgrounded when iPhone changes target mode
- reconnect happens after the loading modal has already timed out

Required consequences:
- no destructive cleanup on temporary disconnect
- no early stop of mirror sync before `standaloneReady`
- target/effective/ready state can reconcile after delayed reconnect
- background convergence must be able to finish after foreground UI timeout
