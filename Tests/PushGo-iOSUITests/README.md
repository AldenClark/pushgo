# PushGo iOS UI quality suite

## Purpose

Curated lanes execute only the high-value App-owned journeys listed below. The 22 legacy Runtime command/state or screenshot-diagnostic bodies have been renamed `legacyDiagnostic...`, so XCTest no longer discovers or executes them; they remain temporarily only to support incremental helper removal and must not be used to claim product coverage. The old host-path automation shell runners have been deleted.

A product result passes only when the test uses a reachable user entry and verifies accurate visible data, a real action result, persisted/relaunch state, or an independently meaningful system/data endpoint. Screen identifiers, fixture markers, response files, Runtime state, launch success, and sheet existence are supporting diagnostics only.

## Curated journeys

| Lane | Journey | Product oracle |
| --- | --- | --- |
| PR+ | Empty/content/workflow messages | Functional empty state; accurate list/detail; page-size boundary; read state; filters; relaunch |
| PR+ | Search/delete/undo/commit | Exclusion and exact-result sets; accurate detail; immediate suppression; undo restore or real-deadline permanent removal; unrelated control preserved; relaunch |
| PR+ | Slow/error/refresh | User-visible slow/error states; accurate snapshot retained; provider result persisted; real Retry recovery |
| PR+ | Primary navigation | One real session reaches the unique Messages, Events, Things, Channels, and Settings destinations, then uses the production Getting Started action to hand off to Safari at `pushgo.dev` |
| Nightly+ | Event/Thing | Production ingestion/projection; accurate detail and relations; close/filter/back/relaunch outcomes |
| Nightly+ | Channel | Create, rename, keep-history unsubscribe, delete-history unsubscribe, and relaunch through production UI/Store paths |
| Nightly+ | Settings visibility | Real Event page control changes navigation, reaches the accurate destination, and survives both relaunch directions |
| Nightly+ | Settings server | Invalid input stays in the editor; normalized address persists; gateway-scoped channel data changes immediately and after relaunch |
| Nightly+ | Settings decryption | Invalid key stays in the editor; configured status changes only after persistence; relaunch retains status; the value is not echoed; blank Save is non-destructive across relaunch; explicit Delete remains absent after relaunch |
| Nightly+ | Local configuration failures | Candidate validation may succeed while local gateway commit fails: the old gateway survives restart and retry alone commits; protected key persistence failure stays sheet-owned, remains unconfigured after restart, and retry alone configures |
| Performance | Prepared 1k-message cold launch | Measures full launch-to-exact-content latency, launch responsiveness, CPU, and memory; opens the highest-index row and verifies its exact detail body |
| Physical performance | Dedicated reference-device cold launch | Release build, ten iterations, device-specific full launch-to-exact-content budget, then exact detail verification; never substitutes a personal device or Simulator |

The Settings decryption journeys separately prove configuration persistence, wrong-material safe failure followed by correction, successful recovery of the same canonical encrypted message, and corrupt-ciphertext safe failure across relaunch. Gateway accepted-mutation sessions isolate unavailable remote/FCM/private-transport side effects; they do not prove a public gateway or real provider.

## Lanes

Run the repository wrappers so environment readiness, result classification, evidence capture, and curated scope remain consistent:

```bash
scripts/quality_test.sh pr
scripts/quality_test.sh nightly
scripts/quality_test.sh release

# Opt-in: 50 fresh App-owned functional launches, never a routine PR cost
scripts/run_ios_startup_reliability.sh
```

The performance lane always runs the App-owned Simulator gross-regression gate. A dedicated, pre-seeded reference device is opt-in and must be named explicitly:

```bash
IOS_PERFORMANCE_DEVICE_ID='<device-udid>' \
PUSHGO_PHYSICAL_EXPECTED_TITLE='<pre-seeded exact title>' \
PUSHGO_PHYSICAL_EXPECTED_BODY='<pre-seeded exact body>' \
PUSHGO_PHYSICAL_MAX_SECONDS='<device-specific budget>' \
  scripts/quality_test.sh performance
```

That physical runner proves launch-to-accurate-content only. Frame/hitch traces, APNs delivery, and other real-system claims remain `NOT RUN` until their own evidence is executed.

For a focused journey:

```bash
TEST_SCOPES='PushGo-iOSUITests/PushGo_iOSUITests/testSettingsServerUsesRealControlsAndScopesDataAfterRelaunch' \
  scripts/quality_test.sh focused
```

`scripts/quality_changed.sh` derives the deterministic minimum lane from `config/quality-impact.json`. That plan is a lower bound, not a coverage score.

## Result rules

- Business assertion failures are never retried.
- Product and preparation failures are never retried. The former pre-action Simulator compatibility retry was removed after a clean 50/50 App-owned startup campaign; a new failure before any Test Case is now `BLOCKED` for fresh attribution, not retried into green.
- Missing readiness, invalid session control, or unavailable infrastructure is `BLOCKED`, not a timed-out product failure.
- Opt-in scale/performance tests absent from a run are `NOT RUN`, never counted as passed.
- Simulator evidence does not prove APNs, physical accessibility, background delivery, signing, install/upgrade, or other real-system behavior.
- UI launches use an App-owned session Store and built-in synthetic fixtures. Tests do not ask the App to read a host database or host fixture path.

The migration disposition and remaining weak tests are tracked in `docs/quality/current-test-disposition.md`; capability truth and residual gaps are tracked in `docs/quality/capability-coverage.md` and the quality-overhaul workstream.
