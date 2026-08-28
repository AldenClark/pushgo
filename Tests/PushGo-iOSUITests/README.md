# PushGo iOS UI quality suite

## Purpose

This target contains two generations of tests. Curated lanes execute only the high-value App-owned journeys listed below. Legacy Runtime command/state tests remain temporarily for migration diagnostics and must not be used to claim product coverage.

A product result passes only when the test uses a reachable user entry and verifies accurate visible data, a real action result, persisted/relaunch state, or an independently meaningful system/data endpoint. Screen identifiers, fixture markers, response files, Runtime state, launch success, and sheet existence are supporting diagnostics only.

## Curated journeys

| Lane | Journey | Product oracle |
| --- | --- | --- |
| PR+ | Empty/content/workflow messages | Functional empty state; accurate list/detail; page-size boundary; read state; filters; relaunch |
| PR+ | Search/delete/undo | Exclusion and exact-result sets; accurate detail; immediate suppression; undo; relaunch |
| PR+ | Slow/error/refresh | User-visible slow/error states; accurate snapshot retained; provider result persisted; real Retry recovery |
| Nightly+ | Primary navigation | Real controls reach the unique Messages, Events, Things, Channels, and Settings destinations |
| Nightly+ | Event/Thing | Production ingestion/projection; accurate detail and relations; close/filter/back/relaunch outcomes |
| Nightly+ | Channel | Create, rename, keep-history unsubscribe, delete-history unsubscribe, and relaunch through production UI/Store paths |
| Nightly+ | Settings visibility | Real Event page control changes navigation, reaches the accurate destination, and survives both relaunch directions |
| Nightly+ | Settings server | Invalid input stays in the editor; normalized address persists; gateway-scoped channel data changes immediately and after relaunch |
| Nightly+ | Settings decryption | Invalid key stays in the editor; configured status changes only after persistence; relaunch retains status; the value is not echoed; blank Save is non-destructive across relaunch; explicit Delete remains absent after relaunch |

The Settings decryption journey proves key configuration persistence, not successful recovery of a representative encrypted message. The latter remains a separate P0 gap. Gateway accepted-mutation sessions isolate unavailable remote/FCM/private-transport side effects; they do not prove remote rejection, compensation, or a real provider.

## Lanes

Run the repository wrappers so environment readiness, result classification, evidence capture, and curated scope remain consistent:

```bash
scripts/quality_test.sh pr
scripts/quality_test.sh nightly
scripts/quality_test.sh release
```

For a focused journey:

```bash
TEST_SCOPES='PushGo-iOSUITests/PushGo_iOSUITests/testSettingsServerUsesRealControlsAndScopesDataAfterRelaunch' \
  scripts/quality_test.sh focused
```

`scripts/quality_changed.sh` derives the deterministic minimum lane from `config/quality-impact.json`. That plan is a lower bound, not a coverage score.

## Result rules

- Business assertion failures are never retried.
- One bounded retry is allowed only for a classified pre-action Simulator/runner failure; the test-system result remains `FLAKY`.
- Missing readiness, invalid session control, or unavailable infrastructure is `BLOCKED`, not a timed-out product failure.
- Opt-in scale/performance tests absent from a run are `NOT RUN`, never counted as passed.
- Simulator evidence does not prove APNs, physical accessibility, background delivery, signing, install/upgrade, or other real-system behavior.
- UI launches use an App-owned session Store and built-in synthetic fixtures. Tests do not ask the App to read a host database or host fixture path.

The migration disposition and remaining weak tests are tracked in `docs/quality/current-test-disposition.md`; capability truth and residual gaps are tracked in `docs/quality/capability-coverage.md` and the quality-overhaul workstream.
