# Section 25 P0 semantic audit

Audit date: 2026-08-30. Authority: `design/pushgo-app-quality-testing-final-design.md` section 25.

This is a row-by-row completion ledger, not a coverage score. A test name, fixture, identifier, file, build, or readiness marker never closes a row. `V` requires a reachable production entry, a purpose-level visible/data/system endpoint, and retained executable evidence. `P` means only part of the required platforms or semantics is proved. `B` means a named test-system boundary prevented the product oracle. `N` means an externally owned gate was not run. `NA` is allowed only when the platform is outside the design row or the product capability was explicitly removed.

Platform vector order is `I / M / D / W` (iOS, macOS, Android, watchOS). `-` means the row does not apply to that platform. A vector containing `P`, `B`, or `N` keeps the design row open. Evidence freshness is scoped: a focused run can refresh only the claims it actually executed.

## Evidence catalogue

| Code | Executable evidence and purpose boundary |
| --- | --- |
| `A-LAUNCH` | `PushGo_iOSUITests.testQualitySessionUsesAppOwnedStoreAndReachesFunctionalEmptyState`, `testFatalStoreInitializationStopsReadWriteAndRecoversAfterRelaunch`, their macOS counterparts, `build/quality-results/apple-preparation-summary.json`, and retained Store-rebuild xcresults. |
| `D-LAUNCH` | `QualityMessageJourneyInstrumentedTest.emptyFixtureShowsTheFunctionalEmptyStateInAnAppOwnedDatabase`, `fatalStoreInitializationStopsReadWriteAndRecoversAfterRelaunch`, preparation-contract summary, and process-restart host journey. |
| `A-MSG` | iOS/macOS standard, workflow, filter, refresh, Markdown, cleanup, search, delete/Undo and permanent-delete journeys in `Tests/PushGo-{iOS,macOS}UITests`; latest representative receipts are indexed by `apple-pr-summary.json` and `capability-coverage.md`. Badge ingress/owner current receipts: `build/quality-results/ios-badge-owner-final/run-1-20260830-202654.xcresult` and `build/quality-results/macos-badge-owner-final/run-20260830-202934.xcresult`. |
| `D-MSG` | `QualityMessageJourneyInstrumentedTest` purpose journeys. High-unread boundary current receipt: `../pushgo-android/build/quality-results/android-high-unread-final.log`; the temporary raw-`100` rejection is retained beside it. Refresh ingress badge receipt: `../pushgo-android/app/build/outputs/androidTest-results/connected/debug/TEST-Medium_Phone(AVD) - 17-_app-.xml`. |
| `A-ENTITY` | iOS/macOS Event close/failure and Thing relation/search/delete/relaunch journeys, including exact detail/timeline/relation endpoints. |
| `D-ENTITY` | `QualityEntityJourneyInstrumentedTest` plus Room projection/property journeys in `RuntimeDataLayerInstrumentedTest`. |
| `A-CHANNEL` | iOS/macOS Channel lifecycle journeys: existing subscribe, accepted create, rename, both unsubscribe outcomes, history/stat projection and relaunch. macOS additionally has an external Pasteboard equality oracle. |
| `D-CHANNEL` | `QualityChannelJourneyInstrumentedTest`, Channel transaction integration tests, exact ClipboardManager result, statistics and relaunch. |
| `A-SET` | iOS/macOS Gateway, visibility, decryption, protected-store and documentation journeys plus their Core contracts. |
| `D-SET` | `QualitySettingsJourneyInstrumentedTest`, notification-permission/Doze host journeys and transport integration tests. |
| `A-INGRESS` | Apple Core ingress/dedup/order/ACK contracts and system-notification simulator journeys. Simulator push proves the local OS boundary, not real APNs. |
| `D-INGRESS` | Android parser/coordinator/ledger/Worker integration tests and `QualitySystemNotificationJourneyInstrumentedTest`. |
| `A-DELETE` | iOS/macOS pending deletion coordinator/Store contracts plus real Undo, deadline commit and relaunch journeys. |
| `D-DELETE` | Android pending deletion coordinator/Worker/Room tests plus real Undo, deadline commit, storage recreation and notification cleanup journeys. |
| `A-RELEASE` | `apple-release-summary.json`, generic Release builds and Runtime-isolation contracts. External signing, physical devices and providers remain separate. |
| `D-RELEASE` | `android-release-summary.json`, Release Runtime isolation, update-feed contracts and controlled emulator install evidence. External physical/OEM/provider gates remain separate. |
| `W-CORE` | `PushGo_watchOSUITests.testCoreWatchJourneyShowsAccurateObjectsDeletesOneAndPersistsAfterRelaunch`, migration journey, and `watchos-hermetic-final` / `watchos-migration-final` xcresults. |
| `A-A11Y` | Apple localization-resource contracts, iOS zh-Hans accessibility5 purpose journey and platform semantics tests. |
| `D-A11Y` | Android localization-resource contracts, semantic tests and zh-CN fontScale 1.5 purpose journey. |
| `M-WINDOW` | macOS native minimize/close/status-item restore journey and `macos-window-minimize-final`; the wrong status-item action is retained as a failing control. |

## 25.1 Launch, Store, migration and recovery

| Line | P0 purpose | I/M/D/W | State | Evidence or exact remaining closure |
| --- | --- | --- | --- | --- |
| 1253 | Fresh-install cold launch | V/V/V/- | `V` | `A-LAUNCH`, `D-LAUNCH`: accurate Empty/Content and usable navigation, not a launch marker. |
| 1254 | Standard-data cold launch | V/V/V/- | `V` | `A-MSG`, `D-MSG`: exact row fields and unread state reach real detail. |
| 1255 | Two-second Store delay | V/V/V/- | `V` | Existing positive journeys require visible Loading followed by accurate content. |
| 1256 | Temporary query/I/O failure and Retry | V/V/V/- | `V` | Apple and Android failure journeys require owned error, a new request and accurate recovery. |
| 1257 | Fatal Store initialization failure | V/V/V/- | `V` | `A-LAUNCH`, `D-LAUNCH`: no business UI/Empty masquerade, safe stop/rebuild and accurate recovered Store. |
| 1258 | Every supported schema upgrade | P/P/P/- | `P` | Representative old-to-current migration and reopen are real, but the final supported-version inventory has not yet been mechanically reconciled against every migration test and retained field family. |
| 1259 | Reopen after migration | V/V/V/V | `V` | Apple iOS/macOS/watch and Android Store/repository reopen consumers retain exact data. |
| 1263 | Session teardown isolation | V/V/V/V | `V` | App-owned session roots plus teardown/relaunch contracts; no host DB path or final verdict path. |
| 1264 | Release Runtime cannot activate | V/V/V/V | `V` | `A-RELEASE`, `D-RELEASE`; Release cannot decode/activate Quality Runtime controls. |

## 25.2 Navigation and page visibility

| Line | P0 purpose | I/M/D/W | State | Evidence or exact remaining closure |
| --- | --- | --- | --- | --- |
| 1270 | Reach Messages/Events/Things/Channels/Settings | V/V/V/- | `V` | Apple `core.positive` and Android primary-navigation journeys reach domain-unique content through real controls. |
| 1271 | Hide Events/Things while keeping legal navigation | V/V/V/- | `V` | `A-SET`, `D-SET`; other pages remain usable and selection falls back legally. |
| 1272 | Visibility persists across restart | V/V/V/- | `V` | Same journeys require ordinary relaunch before accepting the saved state. |
| 1275 | Unread badge count, `99+`, mutations and hidden-page ownership | V/V/V/- | `V` | `A-MSG`, `D-MSG`: high-unread is capped at `99+`; mark-one/all-read, delete and production-shaped refresh ingress drive exact canonical/UI transitions and survive relaunch. iOS/macOS visibility journeys additionally hide Messages and require its badge to disappear across relaunch, then restore the owner and exact badge. Android has no Messages visibility control, so that branch is not product-applicable there. |

## 25.3 Message list, paging, filters and refresh

| Line | P0 purpose | I/M/D/W | State | Evidence or exact remaining closure |
| --- | --- | --- | --- | --- |
| 1284 | Empty Store | V/V/V/- | `V` | Functional Empty is distinguished from Loading by `A-LAUNCH` and `D-LAUNCH`. |
| 1285 | Accurate standard row fields | V/V/V/- | `V` | `A-MSG`, `D-MSG`; exact title/body preview/channel/time/severity/read semantics reach detail. |
| 1286 | 125-row paging without loss/duplication/order drift | V/-/V/- | `V` | iOS traverses 125 rows across three pages; Android current workflow has 134 deterministic rows and crosses page-size 50. The design row excludes macOS. |
| 1287 | Equal-time deterministic tie-break | V/-/V/- | `V` | Apple/Android Store/property contracts reload the same ordered IDs. |
| 1290 | Unread filter | V/V/V/- | `V` | Exact set/count, mark-all transition and relaunch in `A-MSG`, `D-MSG`. |
| 1291 | Channel and ungrouped filters | V/V/V/- | `V` | Five-row hand-computable fixtures verify target/ungrouped sets. |
| 1292 | Tag and combined filters | V/V/V/- | `V` | UI representative AND semantics plus lower-level set algebra; clearing restores the exact set. |
| 1294 | Successful refresh | V/V/V/- | `V` | New production-shaped ingress result appears once, opens exact detail and survives relaunch. |
| 1296 | Mark one read | V/V/V/V | `V` | Exact row and unread count change and remain after relaunch, including current watch evidence. |
| 1297 | Mark current scope read | V/V/V/- | `V` | Scoped filter fixtures prove only the selected set changes; unrelated unread remains. |
| 1300 | Delete and Undo | V/V/V/- | `V` | Same object/content is restored and remains after relaunch. |
| 1301 | Delete without Undo | V/V/V/- | `V` | Production deadline commits only the target; control object remains and deleted target does not revive after storage recreation. |

## 25.4 Search

| Line | P0 purpose | I/M/D/W | State | Evidence or exact remaining closure |
| --- | --- | --- | --- | --- |
| 1310 | Empty-query product semantics | V/V/V/- | `V` | UI and Store contracts preserve the defined full-list/placeholder behavior. |
| 1311 | Case/accent/width/punctuation/CJK normalization | V/V/V/- | `V` | Property/Store matrix covers the input space; representative UI queries reach exact objects. |
| 1312 | Supported title/body/channel/tag/metadata ranges | V/V/V/- | `V` | Store tests enumerate supported fields and avoid claiming unsupported metadata. |
| 1313 | Rapid input cancels stale request | V/V/V/- | `V` | VM latest-query tests and UI accurate final-set guard. |
| 1314 | Slow search feedback without frozen navigation | V/V/V/- | `V` | Existing standard journeys show a real in-layout pending state, then exact results. |
| 1316 | No-result and clear | V/V/V/- | `V` | Exact query Empty followed by restored canonical set. |
| 1317 | Open exact search result | V/P/V/- | `P` | iOS and Android open and compare exact detail. macOS currently proves exact target-only result in the real window, but the retained journey does not yet bind search selection to exact detail fields as a distinct post-search endpoint. |

## 25.5 Message detail, Markdown, media and decryption

| Line | P0 purpose | I/M/D/W | State | Evidence or exact remaining closure |
| --- | --- | --- | --- | --- |
| 1325 | Open exact detail from list | V/V/V/V | `V` | Exact identity and fields in `A-MSG`, `D-MSG`, `W-CORE`. |
| 1326 | Opening detail updates durable read semantics | V/V/V/V | `V` | List/detail/badge and relaunch converge. |
| 1327 | Major Markdown structures are semantic | V/V/V/- | `V` | Production renderers expose table/list/link/code/quote/task structures, not a fixture Text existence check. |
| 1336 | Valid key decrypts to exact plaintext | V/V/V/- | `V` | Core/JVM plus real Settings-to-original-message recovery and relaunch. |
| 1337 | Missing key explains cause and offers Settings entry | V/V/V/- | `V` | Real missing-key message/detail owner and actionable Settings route. |
| 1338 | Wrong key/corrupt ciphertext fails safely and recovers | V/V/V/- | `V` | No garbage plaintext; same canonical ciphertext survives correction/relaunch. |
| 1340 | Detail delete, Undo and relaunch | V/V/V/- | `V` | `A-DELETE`, `D-DELETE`; same semantics as list deletion. |

## 25.6 Events

| Line | P0 purpose | I/M/D/W | State | Evidence or exact remaining closure |
| --- | --- | --- | --- | --- |
| 1347 | Empty and standard Event list | V/V/V/V | `V` | Domain-unique Empty and exact row/detail fields. |
| 1349 | Active/resolved patch and out-of-order canonical head | V/V/V/- | `V` | Apple/Android Store/property contracts reject stale heads while retaining history. |
| 1350 | Search only supported Event fields | V/V/V/- | `V` | Store enumeration plus representative UI result; unsupported metadata is not claimed. |
| 1353 | Exact Event detail and ordered timeline | V/V/V/V | `V` | `A-ENTITY`, `D-ENTITY`, `W-CORE`. |
| 1355 | Close cancel/success converges list/detail/timeline/filter/Thing | P/P/P/- | `P` | Main close, filtering, persistence and Thing-linked views are covered, but the final row audit has not yet demonstrated every platform's cancel branch and all four consumers in one traceable state transition. |
| 1356 | Close failure/retry and duplicate-submit protection | V/V/V/- | `V` | Owned error, canonical ongoing state, disabled duplicate action, retry to closed and relaunch. |
| 1360 | macOS split-view selection/delete fallback | -/P/-/- | `P` | Selection-to-detail is proved. Exact post-delete fallback selection needs a direct retained oracle rather than inference from object disappearance. |

## 25.7 Things

| Line | P0 purpose | I/M/D/W | State | Evidence or exact remaining closure |
| --- | --- | --- | --- | --- |
| 1367 | Empty and standard Thing list | V/V/V/V | `V` | Exact name/state/summary and current image-bearing product fields where fixture supplies them. |
| 1369 | Patch/out-of-order canonical head | V/V/V/- | `V` | Store/property contracts prevent old updates overwriting the current head. |
| 1370 | Search location/external IDs/attrs/related text | V/V/V/- | `V` | Store field matrix plus exact representative UI object. |
| 1371 | Overview and real Events/Messages/Updates tabs | V/V/V/- | `V` | Three actual relation collections, order, details and relaunch are checked. |
| 1372 | Tags/location/metadata values, empty and clear | P/P/P/- | `P` | Value rendering and representative Empty states are covered; tombstone/explicit field-clear convergence is still an identified Store-to-UI gap. |
| 1381 | macOS split-view selection | -/V/-/- | `V` | Exact selected row and detail identity. |

## 25.8 Channels

| Line | P0 purpose | I/M/D/W | State | Evidence or exact remaining closure |
| --- | --- | --- | --- | --- |
| 1387 | Empty state and create/subscribe entries | V/V/V/- | `V` | Real controls enter completable forms, not illustration/text checks. |
| 1388 | Name/ID/password boundaries | V/V/V/- | `V` | Unit/JVM boundary matrix plus representative real form semantics and secret-field privacy. |
| 1391 | Duplicate/auth/limit/not-found recovery | P/P/P/- | `P` | Auth rejection with retained input/retry is real. Duplicate/limit/not-found are not yet all reconciled to reachable product responses and owned recovery actions on every platform. |
| 1394 | Click row copies exact Channel ID | B/V/V/- | `P` | macOS and Android external clipboard equality pass. iOS 27 denies Runner Pasteboard reads and the system Paste consumer attempt was unstable; iOS remains product `N` / test-system `B`, not inferred from toast or other platforms. |
| 1395 | Rename success/cancel/invalid/failure | P/P/P/- | `P` | Accepted rename and persistence are real; the final audit must bind cancel, invalid and remote failure to unchanged old name/retry on every platform. |
| 1396 | Delete confirmation cancel has no local/remote effect | V/V/V/- | `V` | Real cancel followed by exact retained row/history. |
| 1397 | Unsubscribe while preserving history | V/V/V/- | `V` | Subscription stops, exact history/search consumers remain and relaunch preserves state. |
| 1398 | Unsubscribe/delete history with Undo | V/V/V/- | `V` | Undo window and final delete semantics converge with related data. |
| 1402 | Channel total/unread/latest statistics | V/V/V/- | `V` | Canonical message projection and read transition are checked in the real row. |

## 25.9 Settings and platform-specific settings

| Line | P0 purpose | I/M/D/W | State | Evidence or exact remaining closure |
| --- | --- | --- | --- | --- |
| 1408 | Gateway URL valid/invalid/normalized | V/V/V/- | `V` | `A-SET`, `D-SET`: invalid inline owner, candidate validation/registration before commit, normalized saved endpoint and relaunch. |
| 1411 | Token reveal/hide and safe persistence | P/P/P/- | `P` | Secret fields and protected-store failure compensation are covered for decryption/subscription material. The row's generic “Token” must be normalized to each actually user-visible token field and checked for reveal state, secure persistence and relaunch; current evidence cannot be globally inferred. |
| 1413 | Page visibility | V/V/V/- | `V` | Real controls, legal navigation and relaunch in `A-SET`, `D-SET`. |
| 1414 | Decryption key hex/base64 boundaries | V/V/V/- | `V` | Validator matrix plus real invalid and accepted UI paths. |
| 1415 | Saving key recovers original message | V/V/V/- | `V` | Same canonical encrypted message becomes exact plaintext and remains after relaunch. |
| 1421 | Every visible documentation link reaches a safe localized target | V/P/P/- | `P` | Full URL/page/locale mapping has Core contracts and iOS has a real Safari handoff. macOS and Android still need one representative system-consumer handoff each, and the audit must reconcile every currently visible control against the mapping rather than count URL constants. |
| 1422 | Notification-permission card and settings return | V/B/V/- | `P` | iOS and Android exercise real system decisions/Settings and return refresh. macOS notification delivery is authorized and visible, but the current notification card/click surface is not operable through XCTest; the exact remaining macOS Settings-card path must stay `B`, not green. |
| 1426 | Android FCM/Private transport selection | -/-/P/- | `P` | Real UI, durable mode, Service/token/connection state and rollback/relaunch are covered. A real post-switch FCM and Private delivery is externally owned and remains `N`; typed/fake integration cannot close that endpoint. |

## 25.10 Ingress, notification, ACK and system routing

| Line | P0 purpose | I/M/D/W | State | Evidence or exact remaining closure |
| --- | --- | --- | --- | --- |
| 1435 | Plain/encrypted payload canonicalization | V/V/V/- | `V` | Apple Core and Android parser/property contracts plus exact encrypted-message UI recovery. |
| 1436 | Invalid/expired/unknown payload rejection | V/V/V/- | `V` | No canonical row, ACK or success notification is produced. |
| 1437 | FCM/Private same canonical ID deduplicates | V/V/V/- | `V` | Transport integration proves one canonical row across routes; not presented as real-provider delivery. |
| 1438 | Same-entry duplicate delivery deduplicates | V/V/V/- | `V` | Ledger/repository and representative system notification prove one row/notification/stat increment. |
| 1439 | Out-of-order Event/Thing ingress | V/V/V/- | `V` | Final projections retain the newest canonical head. |
| 1440 | Persist success with ACK failure | V/V/V/- | `V` | Canonical object remains visible and ACK becomes durable pending. |
| 1441 | Persist failure must not ACK or announce success | V/V/V/- | `V` | Integration failure leaves no half object/success notification and remains retryable. |
| 1446 | Notification tap cold/warm opens exact detail (`P0 Release`) | P/B/P/- | `N` | iOS Simulator and Android emulator cover local OS cold/warm routing. macOS notification is visually delivered but XCTest cannot click it. Dedicated physical-device Release evidence is absent, so the design row remains `N` overall. |
| 1448 | Notification mark-read/delete/copy actions (`P0 Release`) | P/N/P/- | `N` | iOS Simulator mark-read/delete actions and Android local notification mutation endpoints cover parts of the chain. Exact physical action→Store/list/badge/clipboard evidence across applicable platforms is not run. |
| 1450 | Permission denied/allowed (`P0 Release`) | P/-/P/- | `N` | Simulator/emulator purpose journeys are real local-system evidence; dedicated physical iOS/Android token/notification acceptance is not run. |
| 1451 | Real APNs provider-to-device-to-UI (`P0 Release`) | N/-/-/- | `N` | Requires a dedicated signed physical iPhone and sandbox provider credentials. `simctl push` is explicitly insufficient. |
| 1452 | Real FCM-to-service-to-UI (`P0 Release`) | -/-/N/- | `N` | Requires a dedicated physical Android device and real FCM delivery identity. |
| 1453 | Real Private Channel transport/ACK/UI (`P0 Release`) | N/N/N/- | `N` | Requires sandbox endpoint/account and dedicated clients; fake-native and typed fixtures remain integration evidence only. |

## 25.11 Durable deletion, Undo and recovery

| Line | P0 purpose | I/M/D/W | State | Evidence or exact remaining closure |
| --- | --- | --- | --- | --- |
| 1459 | Undo-window recovery | V/V/V/- | `V` | `A-DELETE`, `D-DELETE`: exact object and derived counts return. |
| 1460 | Undo expiry commits once | V/V/V/- | `V` | Target is truly deleted, control data remains, relaunch does not revive it. |
| 1461 | Background transition does not freeze/duplicate commit | V/V/V/- | `V` | Lifecycle/coordinator contracts prove a single time-based commit; representative UI journeys cross lifecycle boundaries. |
| 1462 | Kill process while pending | V/V/V/- | `V` | Reopen contracts apply deadline semantics and real storage-recreation journeys prove the final exact set. |

## 25.12 Export disposition, Apple system surfaces and Android update

| Line | P0 purpose | I/M/D/W | State | Evidence or exact remaining closure |
| --- | --- | --- | --- | --- |
| 1472 | Decide whether export is reachable or remove it | V/V/V/- | `V` | Source/product reachability audit chose removal/not-supported; dead helper/file existence is not counted as a feature. |
| 1473 | Export JSON shape, only if export retained | NA/NA/NA/- | `NA` | Conditional gate is inactive because export was explicitly removed as a product candidate. Reintroduction reactivates this row before UI work. |
| 1489 | Android update candidate/ABI/rollout | -/-/V/- | `V` | JVM policy matrix checks version/channel/SDK/ABI/rollout exact candidate selection. |
| 1490 | Feed signature and canonical JSON | -/-/V/- | `V` | Valid signed canonical feed accepts; mutation/re-encoding attacks reject. |
| 1491 | Install permission/download/verify/install state (`P0 Release`) | -/-/P/- | `N` | Controlled emulator performs the real download/hash/archive signer/PackageInstaller/version/data-retention mechanism. Dedicated physical unknown-sources/OEM policy evidence is not run, so this physical row remains open. |

## 25.13 watchOS current UI and standalone receiving

| Line | P0 purpose | I/M/D/W | State | Evidence or exact remaining closure |
| --- | --- | --- | --- | --- |
| 1498 | Cold launch into Messages | -/-/-/V | `V` | `W-CORE`: correct content, Digital Crown traversal and no permanent Loading. |
| 1499 | Messages/Events/Things tab switching | -/-/-/V | `V` | Domain-unique lists and selected state in one core journey. |
| 1500 | Message row/detail fields including image/link | -/-/-/P | `P` | Exact title/time/severity/body and durable identity are covered. The current fixture does not close image/link rendering and action semantics, so those fields cannot be inferred. |
| 1501 | Opening unread message persists read state | -/-/-/V | `V` | Current `watchos-hermetic-final` core journey verifies unread indicator disappears and remains gone after ordinary relaunch. |
| 1502 | Message delete cancel/confirm persists | -/-/-/V | `V` | Cancel preserves, confirm hides, relaunch does not revive target while control remains. |
| 1503 | Event row/detail fields including image | -/-/-/P | `P` | Exact title/status/severity/decryption/update fields are covered; image behavior is not. |
| 1504 | Thing row/detail key attributes including image | -/-/-/P | `P` | Exact name/state and attributes are covered; image behavior is not. |

## 25.14 Accessibility, localization, visual behavior and performance

| Line | P0 purpose | I/M/D/W | State | Evidence or exact remaining closure |
| --- | --- | --- | --- | --- |
| 1522 | Message/Event/Thing row semantics | V/V/V/P | `P` | Apple and Android semantics/real task representatives cover name, state and primary action. Watch exact visual journeys exist, but the final semantic-accessibility mapping for all three row types is not closed. |
| 1523 | VoiceOver/TalkBack opens, searches and deletes with Undo (`P0 Release`) | N/N/N/N | `N` | Requires dedicated physical accessibility runs and focus-order evidence. Simulator large-font/localization is complementary, not a substitute. |
| 1528 | Supported-language resource completeness | V/V/V/V | `V` | Every production key is non-empty in supported locales and placeholders are compatible; this is intentionally not used as layout evidence. |

## 25.15 macOS windows/status item and service lifecycle

| Line | P0 purpose | I/M/D/W | State | Evidence or exact remaining closure |
| --- | --- | --- | --- | --- |
| 1544 | Status-item left click restores one main window | -/V/-/- | `V` | `M-WINDOW`: actual status item action makes the unique window key/main and preserves exact App-owned data. |
| 1546 | Close/minimize/restore without duplicate windows | -/V/-/- | `V` | Native minimize and close are both exercised; wrong right-click restore action fails the functional-window oracle. |

## Audit result and execution queue

The design contains 103 P0/P0 Release rows. This audit deliberately does **not** declare section 21.2(1) complete:

- 78 rows are currently classified `V`; 1 conditional export row is `NA` because the product capability was explicitly removed.
- 16 rows remain `P` and require semantic closure, an explicit product-scope correction, or an externally owned sub-gate.
- Two platform sub-results are explicitly `B`: iOS Channel Pasteboard and macOS notification interaction. Neither is hidden inside a green aggregate.
- 8 P0 Release/external rows remain `N`; local Simulator/emulator evidence is retained but never promoted to physical/provider acceptance.

The next implementation order is constrained by value and reuse:

1. Close row 1317 on macOS by extending the existing slow-search standard-message journey from exact result set to exact detail, if it adds only the existing row click and field checks.
2. Reconcile row 1258 against the actual supported migration registry before adding any migration UI; add only missing field-family/version coverage at Store level.
3. Audit rows 1355, 1360, 1372, 1391, 1395 and 1411 against existing tests and product reachability; prefer documenting already-real evidence or low-level parameterization over device matrices.
4. Add one representative macOS and Android documentation system handoff for row 1421 only if it can reuse existing Settings/navigation journeys. Keep all page×locale correctness in fast contracts.
5. Keep physical/provider/watch-media/accessibility items in their explicit Release/owner lanes. They cannot displace locally reachable positive P0 work and cannot be turned green with mocks.

Every status change must update this ledger, the platform `capability-coverage.md`, and the retained receipt path in the same slice. A same-context implementation/review remains `common-mode-risk` until an independent blind packet verifies the row mapping.
