# UI entrypoint semantic review

This review is the lightweight source-to-test and test-to-product discovery layer. It does **not** calculate coverage and cannot pass a product capability. Its job is narrower and valuable: expose a new stable production UI contract with no test reference, or a test literal with no corresponding production contract, then require an explicit semantic decision.

The scanner only treats production `accessibilityIdentifier` / `testTag` attachments (including named component tag parameters) as UI entrypoints. Route aliases, Automation `visibleScreen` strings, fixture state and other diagnostic protocol literals are deliberately excluded. Test references may come from XCTest, Compose/UIAutomator or host shell journeys, including a bare identifier passed to a system driver.

## Current review result

| Platform | Stable production identifiers | Test reference identifiers | Unreferenced production | Test-only | Unresolved | Stale dispositions |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Apple | 76 | 82 | 7 | 13 | 0 | 0 |
| Android | 58 | 60 | 6 | 8 | 0 | 0 |

The raw counts are not a score. Every difference is reviewed in `config/quality-ui-entrypoint-dispositions.json` and falls into one of these purpose-based outcomes:

- **semantically covered**: the purpose is already proven by a stronger shared route, real system consumer, exact data result and/or relaunch; another device journey would only repeat an identifier;
- **dynamic/indirect product contract**: the product constructs the final ID from a canonical object/page, while the test uses one concrete ID and still requires the exact business endpoint;
- **dated deferral**: the residual behavior belongs to a P1 closure group with owner and deadline; it remains non-green;
- **component-only**: a reusable component test deliberately supplies a synthetic tag and does not claim a production capability;
- **not a standalone capability**: for example, a passive version row is supporting information; installation is judged from the real installed package/version, retained data and resumed App, not row existence.

Current notable decisions:

- Apple Message API/E2EE links use the full visible-control-to-localized-URL contract plus one real Getting Started browser handoff per platform; three browser journeys would add cost without new routing risk.
- Apple Watch receiver/resync/health and update beta, Android update channel/expiry and channel unsubscribe cancellation remain dated P1 work. The Android stable Skip/relaunch/manual-bypass/version-scope subclaim is now covered by a real emulator journey; the remaining policy and system-return work is not hidden by the zero-unresolved discovery result.
- Android's notification-disabled card and persistent Settings row share `openAppNotificationSettings`; the controlled permission journey already proves the denied explanation, exact PushGo system page, real switch, return refresh and enabled App state.
- Android page-visibility container has no independent action; its child controls must hide, persist, restore and reopen exact destinations. The container tag itself is not an Oracle.

## Enforcement

`scripts/quality_ui_entrypoints.py --dispositions config/quality-ui-entrypoint-dispositions.json` returns `REVIEW_REQUIRED` when a difference is new, a disposition becomes stale, or a review lacks a real reason. The static test runs this against the current Apple tree. The same scanner is also run against the sibling Android tree during this cross-platform overhaul; Android must carry the checker in its own repository before independent CI closure.

`READY_FOR_SEMANTIC_REVIEW` means only that discovery differences have decisions. Identifier overlap remains `REFERENCE_FOUND_SEMANTIC_ORACLE_NOT_PROVEN`; actual closure still comes from `capability-coverage.md`, current test disposition, fresh executable receipts, and the P0/P1 ledgers.

The 2026-09-02 current-byte scans used the Apple `Apps`/`Shared` versus `Tests`/`scripts` roots and the Android `app/src/main` versus `app/src/androidTest`/`app/src/test`/`scripts` roots. Apple and Android each have zero unresolved differences and zero stale dispositions in their respective disposition files. The latest Android report after the stable Skip journey and stale-disposition correction is `../pushgo-android/build/quality-results/android-ui-entrypoints-post-fc07347-20260902.json` (58 production identifiers, 60 test references, 6 source-only, 8 test-only); the Apple report remains `build/quality-results/apple-ui-entrypoints-current-20260902-with-dispositions.json`. These reports remain discovery evidence only, not product coverage or a release gate.
