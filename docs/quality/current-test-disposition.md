# Apple 当前 UI 测试处置清单

基线日期：2026-08-27。此文件是 WP0 迁移清单，迁移完成后归档；它不作为产品通过 Oracle。

## 处置含义

- `keep`：当前 Oracle 已保护真实行为；允许迁移公共 Launcher/Waiter。
- `rewrite`：用户目的有价值，但触发或最终 Oracle 依赖 Runtime command/state/path，必须重写。
- `move`：测试只证明 Store、parser、fixture 或性能 helper，应移到对应低层/性能 suite。
- `delete`：存在性、聚合状态或重复代理没有独立缺陷敏感度；在更强证据通过后删除。
- `diagnostic`：只提供截图、环境或外部系统诊断，不得进入产品绿色汇总。

## iOS：`PushGo_iOSUITests.swift`

| 处置 | 当前测试 | 原因与替代终点 |
| --- | --- | --- |
| rewrite | `testLaunchesIntoMessageList` | 不能只断言 screen id；改为 Empty/Content/Error 正确状态、可操作和无永久 Loading。 |
| rewrite | `testAutomationRequestCanOpenChannelsScreen`、`testNavSwitchTabMatrixCoversPrimaryScreens` | 删除 Runtime 直接导航；改为真实 Tab 点击并检查目标页独有内容、选中和返回。 |
| keep（已迁移） | `testQualityPrimaryNavigationUsesRealControlsAndReachesEachProductScreen` | 单次真实会话点击四个主入口及 Settings，并核对各目标页；替代 Runtime 导航矩阵进入 Nightly/Release。 |
| keep（已迁移） | `testQualityMessageSearchReturnsOnlyTheTargetAndOpensItsRealDetail` | 输入错误查询证明排除集合，再输入目标查询并打开准确正文；替代“App 没崩”Oracle。 |
| keep（已迁移） | `testQualityMessageDeleteUndoRestoresTheSameObjectAcrossRelaunch` | 从真实详情删除，验证行立即隐藏、Undo 可操作、重启后 canonical 对象仍在。 |
| keep（新增目的级证据） | `testQualityMessageDeleteWithoutUndoPermanentlyRemovesOnlyTargetAcrossRelaunch` | 从准确目标详情删除但不撤销，等待生产 5 秒 deadline 自行提交；要求目标永久消失、无关控制消息字段准确，并在完整 App relaunch 后保持该差异。 |
| keep（已迁移） | `testImportedEventFixtureCanOpenEventDetail`、`testImportedThingFixtureCanOpenThingDetail` | 已改为 App-owned 内置 fixture，走真实消息摄入/投影并点击 Tab、列表行、详情字段；不以 response/events 文件作最终 Oracle。 |
| keep（已迁移） | `testEventClosePersistsAndOngoingFilterReflectsRealProjection` | 从真实 Event 行进入详情并确认关闭；关闭载荷经正式通知解析与 canonical projection 更新，验证状态变为 closed、仅进行中筛选排除该事件、重启后 closed 仍保留且关闭动作不再出现。Runtime marker 仅用于启动归因，不作为产品 Oracle。 |
| keep（已迁移） | `testSettingsPageVisibilityUsesRealControlsAndPersistsAcrossRelaunch` | 从真实 Channels→Settings 入口操作 Event 开关，验证 Tab 真实减少/恢复、恢复后可打开准确 Event 页面，并在关闭和恢复后分别 relaunch 核对持久化；替代 Runtime command/state 用例。 |
| keep（新增目的级证据） | `testEncryptedMessageRecoversAfterConfiguringKeyAndSurvivesRelaunch` | 合成密文先经正式通知摄入进入 App-owned Store；用户从真实消息详情进入解密设置并保存匹配格式的合法 Key，最终核对原消息的准确标题/正文、成功状态和 relaunch 持久化。configured 标记、fixture marker 和密钥文件均不是终点。 |
| keep（新增代表性 a11y/l10n 证据） | `testSimplifiedChineseAtAccessibility5CompletesMessageDetailAndChannelCreation` | 先证明实际 SwiftUI Dynamic Type 为 accessibility5 和生产导航为简中，再打开准确消息详情、填写真实频道表单并要求 accepted mutation 生成准确频道行；资源全集由独立合同覆盖，物理 VoiceOver 仍单列。 |
| delete（已被更强旅程替代） | `testPushSettingsCanOpenDecryptionScreen` | 新解密旅程从真实 Channels→Settings 入口操作 invalid/valid key，核对成功状态、不回显、清除和两种 relaunch；仅打开页面不再进入常规 lane。 |
| delete（已被更强旅程替代） | `testInvalidServerAddressShowsInlineFeedbackInsteadOfToast` | 新 server 旅程同时覆盖 invalid 不 dismiss、标准化保存、数据换域和 relaunch；只验证错误呈现的弱重复已移出常规 lane。 |
| rewrite；由新核心旅程替代 | `testFixtureSeedMessagesRefreshesMessageList` | `testQualityStandardMessagesShowAccurateContentAndSurviveRelaunch` 已证明准确行/详情/relaunch；旧 seed count/state 用例应在后续删除。 |
| rewrite | `testSubmittingPopulatedSearchResultsKeepsAppRunning` | “App 仍运行”过弱；改为目标集合、排除集合、最新 query 和打开准确详情。 |
| rewrite | `testFixtureSeedEntityRecordsPublishesProjectionCounts`、`testFixtureSeedSubscriptionsPublishesImportState` | 改为真实 Event/Thing/Channel 内容与后续操作；内部 count 只诊断。 |
| delete（已被更强旅程替代） | `testSettingsPageVisibilityCommandCanHideEventPage`、`testSettingsPageVisibilityCommandCanRoundTripEventPage` | `testSettingsPageVisibilityUsesRealControlsAndPersistsAcrossRelaunch` 已覆盖真实入口、动作、准确页面和双向 relaunch；旧 command/state 不再进入常规 lane。 |
| rewrite（通知打开已被更强旅程替代） | `testEntityOpenPublishesEntityStateAndProjectionCounts`、`testMessageOpenPublishesMessageDetailState`、`testNotificationOpenPublishesMessageDetailState` | Entity/Message 仍需真实入口替换；通知打开已由 `PushGo_iOSSystemNotificationTests.testSystemNotificationTapOpensAccurateReadDetailAndPersists` 走真实授权、SpringBoard 投递/点击、准确详情、已读及 relaunch 接管，旧 Runtime command 只保留诊断且不能声明系统路由通过。 |
| delete（已被更强旅程替代） | `testNotificationMarkReadCommandUpdatesUnreadState`、`testNotificationDeleteCommandUpdatesCounts` | Mark as read 与 Delete 均已由真实 SpringBoard action 接管，并分别对账准确 canonical、read/delete 状态、控制对象和 relaunch；旧 Runtime command 不再声明通知动作通过。 |
| rewrite | `testGatewaySetServerCommandUpdatesConfigurationState` | 通过 Settings 编辑保存，并在 contract 层证明后续请求到新 endpoint。 |
| delete | `testBaselineAutomationStateHasNoRuntimeErrors` | Runtime state 无错误不能证明任何用户能力；错误归因转入 readiness/attachment。 |
| rewrite | `testWatchResyncReceiverCommandPublishesReceiverState` | 移入 Watch integration/physical lane，验证真实 generation/revision/ACK 收敛。 |
| delete（持久化部分已被更强旅程替代） | `testSettingsSetDecryptionKeyRejectsInvalidLength`、`testSettingsSetDecryptionKeyAcceptsBase64Key` | 新真实 Settings 旅程接管 invalid、持久化、状态与不回显；实际加密消息恢复仍需独立 P0 旅程，不能由旧 Runtime command/state 冒充。 |
| move | `testRuntimeQualityLargeFixtureLaunchAndListReadiness` | 拆为 Store correctness、XCTMetric 和少量 10k UI；不能由 Runtime 自报性能。 |
| move | `testRuntimeQualityReservedMarkdownFixturesStayBelowGatewayBodyLimit` | 属于 fixture/parser 合同，移到 Core Test。 |
| diagnostic | `testCaptureLocalizedPrimaryScreens` | 保留人工视觉素材生成；差异需评审，不能自动更新后通过。 |

## macOS：`PushGo_macOSUITests.swift`（21 个）

| 处置 | 当前测试 | 原因与替代终点 |
| --- | --- | --- |
| rewrite | `testLaunchesIntoMessageList` | 改为正确首屏状态、独有数据和可导航；不能只看 screen id。 |
| keep/rewrite-oracle | `testSidebarNavigationCoversPrimaryScreens` | 已真实点击 Sidebar；补页面独有内容、选择、键盘/详情一致性。 |
| rewrite | `testAutomationRequestCanOpenChannelsScreen` | 删除 Runtime 导航，合入真实 Sidebar 旅程。 |
| rewrite | `testImportedEventFixtureCanOpenEventDetailFromStartupRequest`、`testImportedThingFixtureCanOpenThingDetailFromStartupRequest` | 去宿主 Fixture 绝对路径和静默 return；从真实列表/系统路由打开并核对对象。 |
| keep | `testSettingsSidebarCanOpenDecryptionOverlay` | 已从真实 Sidebar 和按钮进入；迁移公共 Launcher 后保留。 |
| delete | `testSettingsScreenControlMatrixShowsCriticalGroups` | 仅检查控件存在；对应用户任务分别由 Server/Visibility/Decryption 测试保护。 |
| keep/rewrite-launcher | `testInvalidServerAddressShowsInlineFeedbackInsteadOfToast` | 保留真实输入/反馈；增加旧 endpoint 未变化 Oracle。 |
| rewrite | `testSettingsPageVisibilityCommandCanHideEventPage`、`testSettingsPageVisibilityCommandCanRoundTripEventPage` | 真实点击设置、切换 Sidebar、relaunch；删除 command/state/event 文件判定和静默 return。 |
| rewrite | `testFixtureSeedEntityRecordsPublishesProjectionCounts`、`testFixtureSeedSubscriptionsPublishesImportState` | App-owned Scenario；最终看真实列表/详情/Channel 行与动作。 |
| rewrite | `testEntityOpenPublishesEntityStateAndProjectionCounts`、`testMessageOpenPublishesMessageDetailState`、`testNotificationOpenPublishesMessageDetailState` | 真实入口打开并核对 id/字段/分栏；不读 state/response/event。 |
| rewrite | `testNotificationMarkReadCommandUpdatesUnreadState`、`testNotificationDeleteCommandUpdatesCounts` | 真实通知动作与 Store/列表/badge/relaunch 对账。 |
| rewrite | `testGatewaySetServerCommandUpdatesConfigurationState` | 真实 Settings 保存 + contract 请求终点。 |
| delete | `testBaselineAutomationStateHasNoRuntimeErrors` | 无独立用户结果；Runtime 错误转为测试系统状态。 |
| move | `testRuntimeQualityLargeFixtureLaunchAndListReadiness` | 拆 Store/performance/UI，删除 state/response 自证和 artifact 静默退出。 |
| move | `testRuntimeQualityReservedMarkdownFixturesStayBelowGatewayBodyLimit` | 移到 Core fixture/parser 合同。 |
| keep（新增目的级证据） | `testClosingMainWindowKeepsAppRunningAndStatusItemRestoresOneFunctionalWindow` | 从真实主窗口关闭按钮进入，要求进程继续运行、App 自有状态栏入口仍可达、恢复后仅一个窗口，且同一 App-owned session 的功能空态仍准确；授权恢复后已在受控本机签名 Runner 真实通过。 |

## 已确认的首要缺陷模式

1. iOS Runner 把 Fixture、response、state、events 的宿主绝对路径传给 App；最终结果大量读取这些文件。
2. macOS 同样使用宿主绝对路径，并在 artifact 不可见时多处 `guard ... else { return }`，会形成假绿。
3. Runtime command 可直接导航、打开对象和修改设置，绕过了应被验证的用户交互。
4. 大量测试最终只检查 `visibleScreen/count/ok/event`；即使 UI 字段错误、列表慢或动作未持久化也可能通过。
5. 性能测试由 Runtime 自报区间且与 UI 正确性混合，必须拆分。

2026-08-28 起，iOS 22 个、macOS 18 个上述旧方法（含截图 diagnostic）已统一改名为 `legacyDiagnostic...`，不再被 XCTest 发现或计入任何 Lane；三套无现行调用方的 host-path Apple/macOS/watchOS automation shell runner 与旧 runtime gap 文档已删除。保留的 legacy body 只用于后续逐步删除其共用 helper，不是可执行测试或覆盖证据。iOS 已有强替代的能力由下列 App-owned 旅程接管；macOS/Watch 尚无强替代的部分继续记为明确缺口，不能因为旧方法仍可编译而声称通过。

## 本轮新增高价值纵向用例

- `testQualitySessionUsesAppOwnedStoreAndReachesFunctionalEmptyState`
- `testQualityStandardMessagesShowAccurateContentAndSurviveRelaunch`
- `testQualityMessageWorkflowLoadsSecondPageAndPersistsReadActions`
- `testQualityMessageSearchReturnsOnlyTheTargetAndOpensItsRealDetail`
- `testQualityMessageDeleteUndoRestoresTheSameObjectAcrossRelaunch`
- `testQualityMessageDeleteWithoutUndoPermanentlyRemovesOnlyTargetAcrossRelaunch`
- `testSlowMessageLoadBecomesVisibleBeforeDataCompletes`
- `testSlowMessageRefreshKeepsAccurateContentVisibleUntilCompletion`
- `testMessageRefreshPersistsNewProviderResultAndOpensItsRealDetail`
- `testMessageRefreshFailureKeepsSnapshotAndRetryRecoversPersistedResult`
- `testMessageLoadFailureShowsRetryAndRecoversToRealDataState`
- `testQualityPrimaryNavigationUsesRealControlsAndReachesEachProductScreen`
- `testEventClosePersistsAndOngoingFilterReflectsRealProjection`
- `testImportedThingFixtureCanOpenThingDetail`
- `testChannelCreateRenameAndBothUnsubscribeOutcomesPersist`
- `testChannelRemoteRejectionStaysInSheetAndRetryPersists`
- `testChannelCreateLocalFailureCompensatesRemoteBeforeRetry`
- `testSettingsPageVisibilityUsesRealControlsAndPersistsAcrossRelaunch`
- `testSettingsServerUsesRealControlsAndScopesDataAfterRelaunch`
- `testGatewayLocalCommitFailureRollsBackBeforeRetryCommits`
- `testSettingsDecryptionRejectsInvalidKeyPersistsAndClearsValidKey`
- `testDecryptionProtectedStoreFailureDoesNotConfigureBeforeRetry`
- `testEncryptedMessageRecoversAfterConfiguringKeyAndSurvivesRelaunch`
- `testCorruptEncryptedMessageFailsSafelyAndSurvivesRelaunch`
- `testSimplifiedChineseAtAccessibility5CompletesMessageDetailAndChannelCreation`
- `PushGo_iOSSystemNotificationTests.testSystemNotificationTapOpensAccurateReadDetailAndPersists`
- `PushGo_iOSSystemNotificationTests.testSystemNotificationDeleteActionRemovesOnlyTargetAndPersists`
- `PushGo_iOSSystemNotificationTests.testSystemNotificationMarkReadActionPersistsAccurateReadTarget`
- `testClosingMainWindowKeepsAppRunningAndStatusItemRestoresOneFunctionalWindow`（macOS controlled runner）
- `testCoreWatchJourneyShowsAccurateObjectsDeletesOneAndPersistsAfterRelaunch`
- `testInvalidHermeticScenarioFailsReadinessExplicitly`
- `testMessageReadFailureStaysOwnedByMessagesWhileOtherDomainsRemainUsable`

消息前十条与高频 Channel 远端拒绝条目进入 PR 核心集，其中 workflow 用 52 条数据跨越真实 page size 50，并验证单条/全部已读、relaunch 与未读筛选。刷新旅程分别证明慢态与上次准确快照共存、Provider 刷新载荷经过规范化摄入后出现在列表和真实详情并在 relaunch 后保留，以及首次失败可见、旧快照保留、同一正式刷新动作重试后恢复；不把直接修改 ViewModel 集合或检查数据库文件当结果。其余真实导航、Entity、Channel 与 Settings 进入 Nightly/Release。Channel 创建补偿必须覆盖凭据/DB 中点失败、本地回滚、远端撤销、正式重载、重试和 relaunch；Server 同样既覆盖候选远端拒绝，也覆盖远端成功后的本地提交中点失败，且 rollback 自身失败不得静默。Decryption 必须覆盖存储失败后重启仍未配置、错误 Key 不产生明文、纠正恢复，以及损坏认证密文安全失败。Release 使用显式高价值清单，不让旧 Runtime/state 绿色覆盖新旅程失败。

系统通知纵切独立成文件和 runner，只在 Nightly/Release 以及自身或通知相关产品代码变更时执行，避免普通 UI 测试改动无差别升级；开发者/AI 可用 `scripts/quality_test.sh system-notification` 做定向归因并生成双状态收据，但它不能替代影响计划要求的 Nightly/Release。宿主 readiness 文件只协调“App 已后台、可以注入”，不读取或写入产品数据库，也不参与产品通过判定；每轮由测试生成唯一 message id、标题和正文并通过原子 readiness contract 交给投递端，防止旧通知命中本轮 Oracle。默认 lane 的首条点击旅程以干净安装重新证明真实授权；后续冷启动/action 旅程保留这份已证明的系统授权，避免短时间连续卸载、重装和授权造成 SpringBoard 准备竞态，但仍各自建立独立 App-owned session、唯一 payload，并先确认宿主确实已安装。热启动与终止进程冷启动都以 SpringBoard 准确通知、真实 `UNNotificationResponse` 路由、详情字段、canonical 列表及重启后的已读持久化为 Oracle。冷启动使用仅 Debug 可解析、五分钟到期、显式关闭的 App-owned lease；Runner 不读取 App 数据库，Simulator 在用户点击前预唤醒 App 也不能把会话消费掉。Mark as read 旅程要求生产 action 保留准确 canonical、消除未读并在 relaunch 后保持；Delete 旅程要求 destructive action 删除目标，同时无关控制消息及正文不变、重启不复活。Simulator `simctl push` 证明系统边界但不等价于真实 APNs 网络；通知中心清理也不能用 App 前台时“SpringBoard 文本不可见”冒充，因此两者继续明确为 `NOT RUN`。

readiness 之前的 App-owned session、系统授权操作、后台切换和 Runner 临时目录写入统一标记为 `QUALITY_PRECONDITION`；失败时产品状态为 `NOT_RUN`、测试系统为 `BLOCKED`。readiness 之后的 SpringBoard 字段、点击/动作路由、详情、已读或删除结果、准确 canonical/无关控制对象和 relaunch 数据才是产品 Oracle，失败记 `FAILED`，防止准备问题与真实产品回归互相污染。

该纵切已有三类负控：把注入正文改错时，点击旅程在 SpringBoard 精确正文断言处失败；把生产 Delete action 故意接到 mark-read handler 时，删除旅程在 canonical 目标仍存在处失败；把生产 Mark as read action 故意接到 delete handler 时，已读旅程因目标 canonical 不再可操作而失败。三者均被 runner 归为产品 Oracle `FAILED`，恢复生产字节后必须再次全程通过，防止“有任意通知/按钮能点/通知 UI 消失”这种形式判定冒充内容、路由、已读或持久删除正确。

Quality session 不再只隔离 GRDB：server config、decryption material metadata 与手动编码偏好由 App 自己的 session `config` 目录持有，同 session relaunch 可读、不同 session 不共享，生产 Keychain/gateway token/fallback 不读不写。配置文件损坏或权限错误必须阻断 readiness，不能被默认值伪装成成功。首次完整 Release 的 2/18 失败正是该隔离缺口的负控证据；结构修复后定向 3/3 与完整 18/18 均通过，原失败结果包继续保留。

## 变更影响门禁

`config/quality-impact.json` 把当前产品源码分配到 Messages、Entity、Channel/Settings、Ingress、系统表面、Watch、App shell、共享 UI/媒体、Performance 和 Release 等具名能力。`scripts/quality_changed.sh` 先执行选择器负控，再运行不低于推荐值的真实 Lane；独立性能测试/runner 变更选择 `performance`，与产品规则同时变化则提升到同时执行功能和性能的 `release`。新产品路径未映射时直接 `BLOCKED`。这只是确定性下限，不能替代对 caller、Store、错误分支和平台消费者的语义追踪。

计划中的 `required_checks` 是必须实际执行并写入收据的补充证据：Appcast/App Store metadata 使用快速语义契约，不启动完整 Release；Fastlane/构建/隐私/回滚变更强制执行发布静态契约并保持 Release Lane。两端各 120 次历史回放已校准旧路径漏选；无效或未知计划直接 `BLOCKED`，不回退为默认绿色。

## Test-system/flake 处置

`config/quality-test-system-issues.json` 取代 runner 内不可审计的“已知失败”口头清单。App-owned 准备失败由 0 重试的 `apple-quality-precondition` 归因；签名、owner、到期日和退出条件均由 `quality_test_system_issues.py` 校验。原 `apple-simulator-xctest-runner-launch` 在 50/50 App-owned 功能启动后已 resolved，通用 iOS Runner 不再允许一次隔离重跑；新的 Test Case 前未知 Runner 故障直接 `BLOCKED`，产品断言仍为 `FAILED`。完整规则见 `docs/quality/test-system-issue-governance.md`。

四个 100k/Watch/concurrency 重型用例已从函数内提前 return 改为框架条件禁用；日常输出必须显示 skipped，并在结果 `not_run` 中列出。`scripts/quality_test.sh performance` 先用 doctor 的 `--host-only` 模式执行 `RuntimeQualityLargeScaleTests`，再在专用 Simulator 执行独立文件 `PushGo_iOSPerformanceTests.swift` 中的 `testPreparedLargeMessageStoreColdLaunchReachesAccurateContent`：数据准备在测量区间外，5 次正式样本采集 launch/clock/CPU/memory，测试端完整启动到准确首行不得超过 8s，最后必须打开相同 persisted body。该 8s 只防 Simulator 明显退化。显式提供参考设备 ID、准确 sentinel 与设备预算时，同一 Lane 继续调用 `scripts/run_ios_physical_performance.sh`，在 Release 配置固定真机执行 10 次；缺条件保持 `NOT_RUN`，不得回落到个人真机或 Simulator。Release 是功能与性能共同超集。ETTrace 仅在指标失败后临时接入做归因，不作为生产或常驻测试依赖。

## macOS 窗口生命周期验证与攻击记录

- 根因归因：状态栏左键与菜单动作都只调用 `showMainWindow()`；旧实现仅持有弱引用并查找现存窗口，既没有保证 close 后窗口仍被保留，也没有在最小化时显式恢复，因此“关闭/最小化”与“窗口不存在”被错误地当作同一状态。
- 实施：`MacMainWindowPresenter` 强持有唯一主窗口、设置 `isReleasedWhenClosed = false`、按固定 identifier 接管丢失 capture 的窗口，并在聚焦前显式 deminiaturize。AppDelegate 的状态栏按钮增加稳定、可访问的产品级 identifier；UI 用例最终仍看唯一窗口和同一 Store 功能态，不以 identifier 本身作为通过终点。
- 负控：临时删除 `makeKeyAndOrderFront` 后，关闭恢复测试在 `window.isVisible` 精确失败，最小化测试在调用次数精确失败；恢复实现后 3/3 通过，证明 Oracle 对“找到了窗口但没有真正显示”敏感。
- 集成攻击：首次 `build-for-testing` 发现新文件只进入 SwiftPM、未进入 Xcode macOS Sources phase；组件测试绿色不能掩盖产品未集成。补齐工程 membership 后 macOS App + UI target 构建通过。
- 测试系统归因：历史授权失败发生在测试方法进入前，因此当时正确记录为 `BLOCKED/NOT RUN`。授权恢复后，受控签名 Runner 的关闭→状态栏→唯一窗口→同一 App-owned 功能空态旅程 1/1 通过；加入 Event/Thing、Gateway 两条失败恢复、页面可见性、解密、消息删除、动态侧边栏及 Event 失败恢复后，当前二十二条正式核心旅程零重试 22/22，结果包 `build/quality-results/macos-ui-22-final/run-20260829-130358.xcresult`。
- 崩溃归因：主导航首次真实执行发现 Message `HSplitView` 切换到 Event/Thing `HSplitView` 会在 AppKit `SplitViewChildController` 约束更新循环中崩溃。固定 300pt 列本就不提供用户可调语义，故三个页面统一改为 `HStack + Divider`；对象优先和完整往返导航均通过。页面级 identifier 另改为独立 1×1 语义标记，避免覆盖后代业务元素。
- Runner 卫生：正式 `scripts/run_macos_ui_tests.sh` 零重试，默认精确选择当前二十二条可发现的高价值旅程；契约测试要求源码 `test...` 集合与 Runner scope 完全相等，防止新增能力被静默漏跑。它先通过 `IOConsoleLocked` 证明交互桌面已解锁，并在 Runner 生命周期持有 `caffeinate` 防止长批次中途空闲锁屏；锁屏直接归测试系统 `BLOCKED`，不再误报产品激活失败。XCTest 在每条旅程的 `setUp/tearDown` 终止本用例启动的 App，并在前后各观察一个安静窗口、关闭 bundle id 精确匹配的系统 `Problem Reporter`；外层 Runner 另在整批开始前、结束后及中断/退出时按系统可执行路径精确清场，无法关闭同样归 `BLOCKED`。因此某条崩溃仍保留产品 `FAILED`，但延迟出现的弹窗不会遮挡后续旅程，也无需为每条方法重启一次不稳定的 UI-test Runner；方法进入前失败归 `BLOCKED`，已执行 Oracle 失败归产品 `FAILED`。精确进程清理的独立契约 2/2 通过。
- Apple 本机交互门禁：`scripts/require_unlocked_apple_ui_console.sh` 现由 macOS、iOS Simulator 与 watchOS Simulator 三个正式 UI Runner 共用；锁屏时三者都在启动构建/模拟器和任何产品动作前退出 2、写入 `BLOCKED`，并分别报告 `macos`、`ios_simulator`、`watchos_simulator` 原因。当前真实锁屏负控三入口均精确命中；共享门禁及三个 Runner 也由影响选择器纳入 `quality-system-trustworthiness` 的 PR 证据，不再被脚本忽略规则归为 `NOT_RUN`。
- 数据加载纵向样板：App-owned standard 数据验证真实行的准确 title/body 语义、真实详情和进程重启持久化；8 秒受控延迟必须先显示 slow 提示再进入准确空态；首次失败必须显示真实错误并由可点击 Retry 恢复。初版标准数据 Oracle 错把 VoiceOver 合并行当作 `staticTexts`，首轮精确失败后改为校验真实行的 label/value，详情根 identifier 也拆为独立 marker，避免吞掉详情内容。
- 刷新产品缺口：macOS 原 `.refreshable` 无显式入口且丢弃 Provider outcome，旧数据继续显示会掩盖慢/错。现增加真实 Refresh 工具栏按钮、慢态和 Messages-owned 失败态；失败保留原准确行，同入口 Retry 写入并打开准确新详情，relaunch 后仍存在。临时移除 slow marker 的负控在预警 Oracle 精确失败，恢复后 focused 2/2。
- Event/Thing 目的链：Event 用例核对准确行与详情，确认关闭后必须看到真实 canonical projection 变为 closed、动作消失并跨进程保留；Thing 用例核对 identity/summary，实际点击三个关系页签和三类详情，要求 canonical 正文准确、Sheet 可返回且 relaunch 后关系仍在。真实执行先暴露并修复关系行点击区域不触发、三个并列 Sheet 状态所有权，以及 Event projection 丢弃 canonical body 三个产品问题。
- 红蓝与双向反查：将关闭回送的 `event_state` 临时从 closed 改为 active 后，用例在 `field.event.detail.status.closed` 的业务终点精确失败（`build/quality-results/macos-ui-event-negative/run-20260829-004716.xcresult`）；恢复后 focused 1/1 与默认 12/12 通过。source→test 覆盖 close action/delivery/persistence、Thing 三关系导航与 Event body fallback；test→product 每个最终 Oracle 均落在准确用户可见数据、可操作性或 relaunch 持久化，不以文件、版本、identifier 存在作为通过终点。
- Gateway 当前证据：候选注册拒绝→Sheet owner→不覆盖旧地址→重试成功→旧数据换域→relaunch 与 commit 中点失败→即时/重启回滚→重试后才换域均 focused 通过，同进程聚合 2/2 通过，并进入当前默认十八条。首次 commit 旅程因 65 字节测试会话 ID 超限正确归为 `FAILED_TEST_SYSTEM`；缩短并在 launch 前执行同合同校验后通过，未放松产品 Oracle。临时把 production candidate prepare 替换为常量、绕过注册时，用例精确失败于“拒绝必须留在编辑器”；恢复真实 prepare 后同例 1/1 通过，负控与恢复结果包分别为 `build/quality-results/macos-ui-gateway-bypass-negative/run-20260829-094611.xcresult`、`build/quality-results/macos-ui-gateway-bypass-restored/run-20260829-094735.xcresult`。
- 页面可见性当前证据：真实 Event Toggle 关闭后导航入口立即消失，第一次进程重启仍隐藏；同一控件恢复后入口可达准确 Event 页面，第二次重启仍可达。首轮 `build/quality-results/macos-ui-page-visibility/run-20260829-100216.xcresult` 真实发现 macOS 外层 group identifier 覆盖三个子按钮；移除覆盖后按钮独立可达。测试曾把本地化辅助值写死为英文，按测试系统问题删除低价值形式 Oracle。持久化层临时把 Event 错写为开启时，负控在第一次重启精确失败（`build/quality-results/macos-ui-page-visibility-negative/run-20260829-100542.xcresult`）；恢复后当时默认 15/15、扩展后的当前默认 18/18 均通过。
- 解密当前证据：真实 Settings 生命周期、受保护写失败与重试、错 Key→正确 Key 恢复、坏密文安全失败四条 4/4 零重试通过（`build/quality-results/macos-ui-decryption-final-four/run-20260829-104646.xcresult`）。用例以 Sheet 排他错误、准确配置状态、同一 canonical 消息的精确标题/正文与 relaunch 为终点；wrong-key 是反例，corrupt+matching-key 是安全变形。首轮同时归因掉敏感辅助 value 不暴露正文及中文输入法候选字两个测试系统问题，并真实发现“列表已恢复、详情仍旧 seed/cache”；移除 seed 快捷路径、按 Store revision 同步并重建详情身份后修复。预修复证据为 `build/quality-results/macos-ui-decryption-input-fixed/run-20260829-103508.xcresult`。
- Event 失败恢复当前证据：iOS/macOS 用同一状态机 `ongoing → closing → rejected/ongoing → closing → canonical closed → relaunch closed`，首次拒绝不丢准确详情，错误留在详情 owner，提交中动作不可重复；重试只通过 production-shaped delivery 与正式持久化更新 canonical。真实执行发现并修复 quality scenario 误落入密码前置分支、macOS `active` 被误判 unknown、iOS 条件替换工具栏仍可点击三类产品/集成问题。临时删除 iOS `.disabled(isClosing)` 后，用例在防重复 Oracle 精确失败（`build/quality-results/ios/run-1-20260829-124750.xcresult`）；恢复哈希与通过版本一致。2.5 秒仅是 Debug 故障注入可观察窗口，不是性能证据。
- 同上下文红蓝审查：实现、归因与审查仍由同一上下文完成，保留 `common-mode-risk`；当前默认 scope 包含二十二条明确旅程并已零重试 22/22，但不扩张到 Thing 筛选/深链/删除、通知、性能、真实 Gateway 网络或物理可访问性。

## watchOS 真实 UI 迁移、归因与攻击记录

- 迁移边界：旧 `PushGo-watchOSAutomation` 已删除；新 `PushGo-watchOSUITests` 由 App 根据 profile/scenario/session 自行准备隔离 Store，Runner 不写 App 容器。历史报告里的旧脚本命令仅是归档证据，不再可执行，也不能声明当前 UI 功能通过。
- 目的级 Oracle：同一真实会话核对两条 Message 的准确标题/正文/严重度，打开详情并分别验证取消与确认删除；确认后必须自动离开已删除详情，重启后删除仍成立。随后通过真实 Tab 手势核对 Event 与 Thing 的列表/详情、状态、正文和属性键值。测试 ID 仅负责可靠定位，不作为最终通过条件。
- readiness 与归属负控：不支持的 App-owned scenario 必须在 UI 明确显示启动失败和准确原因，不允许回退为空列表或生产数据。另用 Store 层消息读取故障证明错误只停留在 Messages，Event/Thing 仍能打开准确对象；Runner/Simulator 无法启动归为 `BLOCKED`，已进入但用户结果错误归为 `FAILED`。
- 产品归因：首次真实旅程先发现删除写入成功后仍滞留在已经不存在的详情页；修复为目标从 Store 消失后清理导航路径。随后发现 Thing 属性只展示原始 JSON、用户无法辨认字段；改为正式解析后的 key/value 行。三类列表此前也会把 Store 错误误报为空态，现统一显示错误与真实 Retry。
- 负控证据：修复前的真实运行分别在“删除后应返回列表”和 `region=eu-west` 可见字段处精确失败；滚动可见性问题只增加有界手势，没有给断言加重试或降低字段要求。错误归属反向审查又先让严格但偏题的内部故障文案 Oracle 失败，随后保留“错误可见、Retry 可操作、其他域任务准确”的目的级判定。最终代表套件 3/3 通过；最终 Lane 结果以本轮新结果包为准。
- Release 隔离：Hermetic runtime 全部受 `#if DEBUG` 限制；影响规则将 watch runtime/AppEnvironment 提升到 Release，Release Lane 同时构建 iOS 与 watchOS，防止调试测试入口污染正式产物。
- 同上下文红蓝审查：实现、失败归因、修复与本轮审查由同一上下文完成，仍有 `common-mode-risk`；因此只声明代表性 Messages/Event/Thing 链路，绝不外推 mark-read mirror ACK、图片/解密、Receiver Health、物理通知/complication、VoiceOver 或字号矩阵已经通过。
