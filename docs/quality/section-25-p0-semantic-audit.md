# Section 25 P0 semantic audit

Audit date: 2026-08-31. Authority: `design/pushgo-app-quality-testing-final-design.md` section 25.

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
| `A-CHANNEL` | iOS/macOS Channel lifecycle journeys: existing subscribe, accepted create, rename cancel/invalid/remote-rejection/retry/success, both unsubscribe outcomes, history/stat projection and relaunch. Rename failures remain in the owning Sheet with the submitted value and unchanged canonical row; current receipts: `build/quality-results/ios-channel-rename-sheet-final-3/run-20260830-2301.xcresult` and `build/quality-results/macos-channel-rename-sheet-final-3/run-20260830-2304.xcresult`. Both platforms now have an external system Pasteboard equality oracle; the current iOS receipt is `build/quality-results/ios-channel-pasteboard-system-final/run-1-20260901-014621.xcresult`. |
| `D-CHANNEL` | `QualityChannelJourneyInstrumentedTest`, Channel transaction integration tests, exact ClipboardManager result, statistics and relaunch. The existing positive lifecycle method now proves rename cancel/invalid/remote-rejection/retry/success without another fixture or App launch; current receipt: `../pushgo-android/build/quality-results/android-channel-rename-ownership-final-3.log`. |
| `A-SET` | iOS/macOS Gateway, visibility, decryption, protected-store and documentation journeys plus their Core contracts. User-visible Gateway Token and message-decryption Key both prove masked default, exact reveal, re-mask and relaunch-safe persistence in existing purpose journeys. Current receipts: `build/quality-results/ios-secret-visibility-final/run-20260830-2343-gateway.xcresult` (Gateway 1/1 after removing the real Password AutoFill overlay), `build/quality-results/ios-secret-visibility-final/run-20260830-2354-decryption.xcresult` (decryption 1/1 on final product bytes), and `build/quality-results/macos-secret-visibility-final/run-20260830-2345.xcresult` (2/2). APNs/FCM device tokens are system-generated, not user-editable fields, and are outside this row. |
| `D-SET` | `QualitySettingsJourneyInstrumentedTest`, notification-permission/Doze host journeys and transport integration tests. The existing Gateway journey now proves Password semantics, exact reveal/re-mask and persisted secret after activity recreation; the existing decryption recovery journey already proves the same visible-secret semantics and then exact message recovery. Current Gateway receipt: `../pushgo-android/build/quality-results/android-gateway-secret-visibility-final.log` (1/1). System-generated FCM tokens are outside the user-visible-field row. |
| `A-INGRESS` | Apple Core ingress/dedup/order/ACK contracts and system-notification simulator journeys. Simulator push proves the local OS boundary, not real APNs. |
| `D-INGRESS` | Android parser/coordinator/ledger/Worker integration tests and `QualitySystemNotificationJourneyInstrumentedTest`. |
| `A-DELETE` | iOS/macOS pending deletion coordinator/Store contracts plus real Undo, deadline commit and relaunch journeys. |
| `D-DELETE` | Android pending deletion coordinator/Worker/Room tests plus real Undo, deadline commit, storage recreation and notification cleanup journeys. |
| `A-RELEASE` | `apple-release-summary.json`, generic Release builds and Runtime-isolation contracts. External signing, physical devices and providers remain separate. |
| `D-RELEASE` | `android-release-summary.json`, Release Runtime isolation, update-feed contracts and controlled emulator install evidence. External physical/OEM/provider gates remain separate. |
| `W-CORE` | `PushGo_watchOSUITests.testCoreWatchJourneyShowsAccurateObjectsDeletesOneAndPersistsAfterRelaunch`, migration journey, and retained Watch xcresults. Current media/detail receipt: `build/quality-results/watchos-media-final-positive/run-20260831-004800.xcresult`; unchanged migration/readiness/error-owner methods: `build/quality-results/watchos-media-regression/run-20260831-004907.xcresult`. |
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
| 1258 | Every supported schema upgrade | V/V/V/- | `V` | Apple v17 genuinely removes and reapplies every registered v18–v25 migration, then a separate v24 boundary preserves the exact pending-deletion ID, summary, intent, undoable state and deadline through v25 and a second reopen. Android builds authoritative v27/v28 databases from exported Room schemas, inserts an exact queued legacy-ingress payload and pending-deletion intent, runs the registered production chain to v30, then closes/reopens and rechecks every business field. Apple focused Store tests passed 1/1 for each boundary; Android's migration device class passed 7/7 on API 37. Fast contracts reject migration-chain, registration, schema-export or selected stateful-boundary drift. Table/column existence and final schema numbers are retained only as supporting facts, never the final Oracle. |
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
| 1286 | 125-row paging without loss/duplication/order drift | V/-/V/- | `V` | iOS now uses 125 App-owned canonical rows and, inside the existing persisted-read journey, accumulates every stable row ID encountered across all three production pages, binds each ID to its exact title, checks each visible viewport for unique identities and contiguous newest-first order, then requires the final observed set to equal exactly `0..<125` before continuing read/relaunch assertions. Its focused current-byte run passed 1/1 in 239.070 seconds with zero retry (`ios-125-all-row-oracle/run-1-20260831-092603.xcresult`). Android uses 134 deterministic rows and the same existing journey validates the first/second and second/third boundaries plus the unique oldest row before continuing read/relaunch assertions; its focused emulator run passed 1/1. The design row excludes macOS. |
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
| 1317 | Open exact search result | V/V/V/- | `V` | iOS and Android open and compare exact detail. macOS now first selects a different canonical legacy detail, completes the slow target-only search, clicks the result located by canonical ID, and requires the exact target title/body to replace the old detail; current receipt: `build/quality-results/macos-search-detail-control-final/run-20260830-203953.xcresult`. |

## 25.5 Message detail, Markdown, media and decryption

| Line | P0 purpose | I/M/D/W | State | Evidence or exact remaining closure |
| --- | --- | --- | --- | --- |
| 1325 | Open exact detail from list | V/V/V/V | `V` | Exact identity and fields in `A-MSG`, `D-MSG`, `W-CORE`. |
| 1326 | Opening detail updates durable read semantics | V/V/V/V | `V` | List/detail/badge and relaunch converge. |
| 1327 | Major Markdown structures are semantic | V/V/V/- | `V` | Production renderers expose table/list/link/code/quote/task structures, not a fixture Text existence check. |
| 1336 | Valid key decrypts to exact plaintext | V/V/V/- | `V` | Core/JVM plus real Settings-to-original-message recovery and relaunch. |
| 1337 | Missing key explains cause and offers Settings entry | V/V/V/- | `V` | Real missing-key message/detail owner and actionable Settings route. |
| 1338 | Wrong key/corrupt ciphertext fails safely and recovers | V/V/V/- | `V` | Apple has purpose-level UI/relaunch evidence. Android now has fresh exact emulator execution through production Worker/Private ingress, Room, NotificationManager and scoped ACK ledger: wrong-key/corrupt payloads remain fail-closed without notification/ACK/ledger claim, only the original authenticated ciphertext and identity can recover one canonical row, and ciphertext/identity transplant is rejected. Real provider/physical transport remains separately `NOT RUN` under rows 1451–1453 and is not hidden in this local row. |
| 1340 | Detail delete, Undo and relaunch | V/V/V/- | `V` | `A-DELETE`, `D-DELETE`; same semantics as list deletion. |

## 25.6 Events

| Line | P0 purpose | I/M/D/W | State | Evidence or exact remaining closure |
| --- | --- | --- | --- | --- |
| 1347 | Empty and standard Event list | V/V/V/V | `V` | Domain-unique Empty and exact row/detail fields. |
| 1349 | Active/resolved patch and out-of-order canonical head | V/V/V/- | `V` | Apple/Android Store/property contracts reject stale heads while retaining history. |
| 1350 | Search only supported Event fields | V/V/V/- | `V` | Store enumeration plus representative UI result; unsupported metadata is not claimed. |
| 1353 | Exact Event detail and ordered timeline | V/V/V/V | `V` | `A-ENTITY`, `D-ENTITY`, `W-CORE`. |
| 1355 | Close cancel/success converges list/detail/timeline/filter/Thing | V/V/V/- | `V` | One existing positive journey per platform now proves cancel leaves the Event ongoing, confirm closes it, the list/filter/detail/timeline/Thing projection converge, and a normal relaunch preserves closed without a repeated action. Current receipts: iOS `build/quality-results/ios-event-close-convergence-pass/run-1-20260830-213425.xcresult`; macOS `build/quality-results/macos-event-close-convergence-final/run-20260830-215247.xcresult`; Android `build/quality-results/android-event-close-convergence-final.log`. |
| 1356 | Close failure/retry and duplicate-submit protection | V/V/V/- | `V` | Owned error, canonical ongoing state, disabled duplicate action, retry to closed and relaunch. |
| 1360 | macOS split-view selection/delete fallback | -/V/-/- | `V` | The existing positive Event journey now deletes the selected exact row and requires the remaining `P3 Event Control` title and purpose-bearing summary to replace the detail immediately; row disappearance alone cannot pass. Current receipt: `build/quality-results/macos-event-delete-fallback-final/run-20260830-220415.xcresult`. |

## 25.7 Things

| Line | P0 purpose | I/M/D/W | State | Evidence or exact remaining closure |
| --- | --- | --- | --- | --- |
| 1367 | Empty and standard Thing list | V/V/V/V | `V` | Exact name/state/summary and current image-bearing product fields where fixture supplies them. |
| 1369 | Patch/out-of-order canonical head | V/V/V/- | `V` | Store/property contracts prevent old updates overwriting the current head. |
| 1370 | Search location/external IDs/attrs/related text | V/V/V/- | `V` | Store field matrix plus exact representative UI object. |
| 1371 | Overview and real Events/Messages/Updates tabs | V/V/V/- | `V` | Three actual relation collections, order, details and relaunch are checked. |
| 1372 | Tags/location/metadata values, empty and clear | V/V/V/- | `V` | Existing UI journeys cover populated and empty Thing surfaces. Fast canonical-head contracts now prove tags empty arrays, metadata/external-ID key tombstones and nested/flat location replacement or clear cannot leave stale searchable/displayable values. Apple retained receipt: `build/quality-results/apple-thing-field-clear-final.log`; Android retained receipt: `build/quality-results/android-thing-field-clear-final.log`. Object deletion tombstones remain a distinct deferred capability. |
| 1381 | macOS split-view selection | -/V/-/- | `V` | Exact selected row and detail identity. |

## 25.8 Channels

| Line | P0 purpose | I/M/D/W | State | Evidence or exact remaining closure |
| --- | --- | --- | --- | --- |
| 1387 | Empty state and create/subscribe entries | V/V/V/- | `V` | Real controls enter completable forms, not illustration/text checks. |
| 1388 | Name/ID/password boundaries | V/V/V/- | `V` | Unit/JVM boundary matrix plus representative real form semantics and secret-field privacy. |
| 1391 | Duplicate/auth/limit/not-found recovery | V/V/V/- | `V` | Gateway duplicate subscribe is reconciled to its real idempotent success contract (`created=false`, `subscribed=true`) on Apple and Android, not invented as an error. Fast contract matrices preserve distinct local semantics for authentication, channel-not-found, subscriber-capacity and HTTP 429 rate-limit responses. Existing iOS/Android form journeys prove an owned password/auth rejection keeps input, creates no dirty row and retries to a persistent success; the existing macOS Channel lifecycle now proves the same rejected existing-channel subscription→Sheet-owned message→retained ID/credential field→no row→same-Sheet retry→relaunch path without a new method or App launch. Current macOS receipt: `build/quality-results/macos-channel-recovery-final/run-20260831-000123.xcresult` (1/1, 108.202 seconds, zero retry). The current-byte iOS and macOS `created=false` local-persistence failure compensation journeys each execute 1/1 with zero skips/retries/runtime warnings (`build/quality-results/ios-existing-channel-compensation-current-20260902/run-1-20260902-035344.xcresult`, `build/quality-results/macos-existing-channel-compensation-current-20260902/run-20260902-035507.xcresult`); both retain the Sheet-owned error and inputs, avoid a dirty row, retry successfully and preserve the canonical row after relaunch. This is controlled contract/UI evidence; a public Gateway outage or account policy is not inferred from it. |
| 1394 | Click row copies exact Channel ID | V/V/V/- | `V` | All three platforms now use an external clipboard consumer and require exact canonical-ID equality. iOS reuses the existing Channel lifecycle and App launches; its host runner seeds a unique sentinel and observes the dedicated Simulator system Pasteboard with `simctl pbpaste` while the real row action runs. The final 1/1 receipt is `build/quality-results/ios-channel-pasteboard-system-final/run-1-20260901-014621.xcresult` with `external_pasteboard_oracle=PASSED`. The earlier 1.2-second toast assertion remains rejected as unstable and insufficient. |
| 1395 | Rename success/cancel/invalid/failure | V/V/V/- | `V` | `A-CHANNEL`, `D-CHANNEL`: cancel preserves the exact old row; invalid and typed remote rejection remain visibly owned by the rename Sheet/Dialog, retain the submitted value and do not mutate the canonical row; the same open form retries to the accepted name, which survives relaunch. The red controls exposed three distinct test-system/product defects before green: Apple alert identifiers did not bind the input, macOS alert retry lost input, and Android could dismiss/route errors globally; a subsequent Android red showed a disabled post-validation submit being silently dropped, so the test now waits on the action's enabled semantics rather than increasing timeouts. |
| 1396 | Delete confirmation cancel has no local/remote effect | V/V/V/- | `V` | Real cancel followed by exact retained row/history. |
| 1397 | Unsubscribe while preserving history | V/V/V/- | `V` | Subscription stops, exact history/search consumers remain and relaunch preserves state. |
| 1398 | Unsubscribe/delete history with Undo | V/V/V/- | `V` | Undo window and final delete semantics converge with related data. |
| 1402 | Channel total/unread/latest statistics | V/V/V/- | `V` | Canonical message projection and read transition are checked in the real row. |

## 25.9 Settings and platform-specific settings

| Line | P0 purpose | I/M/D/W | State | Evidence or exact remaining closure |
| --- | --- | --- | --- | --- |
| 1408 | Gateway URL valid/invalid/normalized | V/V/V/- | `V` | `A-SET`, `D-SET`: invalid inline owner, candidate validation/registration before commit, normalized saved endpoint and relaunch. |
| 1411 | Token reveal/hide and safe persistence | V/V/V/- | `V` | `A-SET`, `D-SET`: the reachable user-visible secrets are Gateway authentication Token and message-decryption Key. Each platform now proves masked-by-default semantics, an explicit reveal with the exact entered value, re-masking, accepted persistence and relaunch/recreation without default plaintext exposure. iOS additionally suppresses the system save-password overlay for app-scoped tokens, discovered by the real UI journey. Protected-store compensation remains covered separately. APNs/FCM registration tokens are generated system material without a user reveal/edit surface and are deliberately not inferred into this row. |
| 1413 | Page visibility | V/V/V/- | `V` | Real controls, legal navigation and relaunch in `A-SET`, `D-SET`. |
| 1414 | Decryption key hex/base64 boundaries | V/V/V/- | `V` | Validator matrix plus real invalid and accepted UI paths. |
| 1415 | Saving key recovers original message | V/V/V/- | `V` | Same canonical encrypted message becomes exact plaintext and remains after relaunch. |
| 1421 | Every visible documentation link reaches a safe localized target | V/V/V/- | `V` | Fast contracts reconcile the actual visible controls rather than URL constants: Apple Settings exposes Getting Started, Message API and E2EE; the Message/Event/Thing onboarding surfaces add their matching API page plus Getting Started; `selfHosting` is mapped but not counted because no current UI exposes it. Android Settings exposes Getting Started, Message API and E2EE, with production row semantics and en/zh-CN/zh-TW resources checked. One representative real system-consumer handoff per platform reuses an existing positive journey: iOS Safari, macOS default browser and Android's resolved browser must receive the exact safe Getting Started HTTPS host/path and return to the same App-owned screen. The iOS fixed PR chain now expands Safari's domain-only bar and accepts only the exact Getting Started path (`build/quality-results/ios-pr-settings-doc-exact/run-1-20260831-073258.xcresult`); redirecting the production mapping to another valid `pushgo.dev` path is retained as a failing sensitivity control (`build/quality-results/ios-pr-settings-doc-exact-negative/run-1-20260831-073533.xcresult`). This proves routing/continuity, not public-site content or network SLA. |
| 1422 | Notification-permission card and settings return | V/V/V/- | `P` | iOS, macOS and Android now exercise real local system decisions/Settings and return refresh. The current macOS byte uses the notification list's semantic `AXIncrementPage` action to bring a virtualized PushGo row into view, then completes the real off→product-owned explanation→on→return disappearance chain: `build/quality-results/macos-notification-permission-current-20260902-r7/run-20260902-104339.xcresult` is 1/1, `Passed`, zero failure/skip/runtime warning, strict verifier `EXECUTED`. The earlier macOS non-hittable-row bundle (`build/quality-results/macos-notification-permission-retry-current-20260901/run-20260901-100618.xcresult`) remains retained as test-system diagnosis, not a product verdict. The row stays `P` because physical-device/system acceptance and external provider boundaries are not run; local Simulator/emulator evidence is not promoted to those Release claims. |
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
| 1446 | Notification tap cold/warm opens exact detail (`P0 Release`) | P/P/P/- | `N` | iOS Simulator and Android emulator cover local OS cold/warm routing. macOS current-byte warm Notification Center click now also requires exact detail/body, unread badge removal and relaunch persistence (`build/quality-results/macos-system-notification-read-oracle-clean-20260902/run-20260902-033118.xcresult`; `EXECUTED`, 1/1, zero warnings). A 2026-08-31 cold-click attempt proved the host can route the click, but LaunchServices selected stale same-bundle DerivedData builds instead of the current test product; targeted competing-process cleanup and current-build registration still could not produce a trustworthy current-byte route (`build/quality-results/macos-ui/run-20260831-064826.xcresult`, `run-20260831-065120.xcresult`, `run-20260831-065356.xcresult`). Experimental code was reverted and the cold sub-gate remains `B/NOT RUN`, rather than accepting any PushGo process as success. Dedicated physical-device Release evidence also remains absent, so the design row stays `N` overall. |
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
| 1491 | Install permission/download/verify/install state (`P0 Release`) | -/-/P/- | `N` | Controlled emulator current byte performs one real `v1.3.0`→`v1.3.1` update through download, SHA-256/package/version/signer checks, `PackageInstaller` replacement, original-path relaunch and exact canonical message retention (`../pushgo-android/build/quality-results/android-update-install-current-20260902/android-update-install/20260902-055743-19960/evidence.json`). Dedicated physical unknown-sources/OEM policy, production signing/feed, interruption and manual-fallback evidence is not run, so this Release row remains open. |

## 25.13 watchOS current UI and standalone receiving

| Line | P0 purpose | I/M/D/W | State | Evidence or exact remaining closure |
| --- | --- | --- | --- | --- |
| 1498 | Cold launch into Messages | -/-/-/V | `V` | `W-CORE`: correct content, Digital Crown traversal and no permanent Loading. |
| 1499 | Messages/Events/Things tab switching | -/-/-/V | `V` | Domain-unique lists and selected state in one core journey. |
| 1500 | Message row/detail fields including image/link | -/-/-/P | `P` | `W-CORE` proves the exact message image reaches the decoded success-only accessibility endpoint with a non-zero rendered frame and accurate label, then finds the real production `Link` by its platform type, label and hittability. A subsequent single zero-retry tap reached the watchOS system surface but ended at `URL failed to load / This URL can be viewed on your iPhone`; `com.apple.Mandrake` never became the foreground consumer (`build/quality-results/watchos-link-discovery/run-20260831-005405.xcresult`). The exploratory code was fully reverted and the system sheet was cleared by a targeted reboot of the PushGo Watch only. This cannot be green on an unpaired Simulator: exact closure requires a paired physical Watch/iPhone to accept the canonical URL and a return endpoint to the same detail. |
| 1501 | Opening unread message persists read state | -/-/-/V | `V` | Current `watchos-hermetic-final` core journey verifies unread indicator disappears and remains gone after ordinary relaunch. |
| 1502 | Message delete cancel/confirm persists | -/-/-/V | `V` | Cancel preserves, confirm hides, relaunch does not revive target while control remains. |
| 1503 | Event row/detail fields including image | -/-/-/V | `V` | `W-CORE` verifies exact title/status/severity/decryption/update fields, requires the decoded image to become a hittable production preview button, taps it, and requires the loaded preview endpoint before returning to the same Event detail. |
| 1504 | Thing row/detail key attributes including image | -/-/-/V | `V` | `W-CORE` verifies exact name/state/attributes plus decoded, labeled image success endpoints in both the real Thing row and detail. Placeholder or cache-preparation success alone cannot satisfy those identifiers. |

## 25.14 Accessibility, localization, visual behavior and performance

| Line | P0 purpose | I/M/D/W | State | Evidence or exact remaining closure |
| --- | --- | --- | --- | --- |
| 1522 | Message/Event/Thing row semantics | V/V/V/V | `V` | Apple and Android semantics/real task representatives cover name, state and primary action. Watch production `NavigationLink` rows now own stable semantic IDs plus exact labels and purpose values: Message exposes title + read state + severity + body, Event exposes title + lifecycle state + severity + summary, and Thing exposes title + available decryption state + business summary. The existing core journey queries those real buttons, checks exact label/value and hittability, opens accurate details, and proves Message unread→read survives relaunch; no new method, fixture or launch was added. This closes simulator semantic mapping only; physical VoiceOver/TalkBack tasks remain row 1523 `N`. |
| 1523 | VoiceOver/TalkBack opens, searches and deletes with Undo (`P0 Release`) | N/N/N/N | `N` | Requires dedicated physical accessibility runs and focus-order evidence. Simulator large-font/localization is complementary, not a substitute. |
| 1528 | Supported-language resource completeness | V/V/V/V | `V` | Every production key is non-empty in supported locales and placeholders are compatible; this is intentionally not used as layout evidence. |

## 25.15 macOS windows/status item and service lifecycle

| Line | P0 purpose | I/M/D/W | State | Evidence or exact remaining closure |
| --- | --- | --- | --- | --- |
| 1544 | Status-item left click restores one main window | -/V/-/- | `V` | `M-WINDOW`: actual status item action makes the unique window key/main and preserves exact App-owned data. |
| 1546 | Close/minimize/restore without duplicate windows | -/V/-/- | `V` | Native minimize and close are both exercised; wrong right-click restore action fails the functional-window oracle. |

## Audit result and execution queue

The design contains 103 P0/P0 Release rows. This audit deliberately does **not** declare section 21.2(1) complete:

- 91 rows are currently classified `V`; 1 conditional export row is `NA` because the product capability was explicitly removed.
- 3 rows remain `P`; two require external/provider or paired-physical-device closure and remain paused by owner direction, while row 1422 has all three local simulator/emulator subclaims current but still lacks physical/system acceptance.
- No current local platform sub-result is `B` in row 1422: the macOS System Settings virtualized-row boundary is closed by a bounded semantic AX page action. Unavailable physical/provider gates remain `N` or the externally owned portion of `P`, never inferred from local green evidence.
- 8 P0 Release/external rows remain `N`; local Simulator/emulator evidence is retained but never promoted to physical/provider acceptance.

The next implementation order is constrained by value and reuse:

1. Keep physical/provider/accessibility items and the remaining Watch system-link handoff in their explicit Release/owner lanes. They cannot displace locally reachable positive P0 work and cannot be turned green with mocks.

Every status change must update this ledger, the platform `capability-coverage.md`, and the retained receipt path in the same slice. A same-context implementation/review remains `common-mode-risk` until an independent blind packet verifies the row mapping.
