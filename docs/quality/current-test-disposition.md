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
| keep（已迁移并扩展系统终点） | `testQualityPrimaryNavigationUsesRealControlsAndReachesEachProductScreen` | 单次真实会话先经已注册 `pushgo://` 外部入口打开准确 Message、Event 与 Thing 详情，分别核对 canonical 正文/摘要并返回 App，再点击四个主入口及 Settings 完成各页真实功能终点；最后从生产 Getting Started 控件拉起真实 Safari，并要求系统可访问性树出现 `pushgo.dev`。精确文档 path/locale 映射由快速 Core 合同全量裁决，避免为每个文档页、语言和平台复制设备 UI。替代 Runtime 导航矩阵进入 PR/Nightly/Release。 |
| keep（已迁移） | `testQualityMessageSearchReturnsOnlyTheTargetAndOpensItsRealDetail` | 输入错误查询证明排除集合，再输入目标查询并打开准确正文；替代“App 没崩”Oracle。 |
| keep（已迁移） | `testQualityMessageDeleteUndoRestoresTheSameObjectAcrossRelaunch` | 从真实详情删除，验证行立即隐藏、Undo 可操作、重启后 canonical 对象仍在。 |
| keep（新增目的级证据） | `testQualityMessageDeleteWithoutUndoPermanentlyRemovesOnlyTargetAcrossRelaunch` | 从准确目标详情删除但不撤销，等待生产 5 秒 deadline 自行提交；要求目标永久消失、无关控制消息字段准确，并在完整 App relaunch 后保持该差异。 |
| keep（已迁移） | `testImportedEventFixtureCanOpenEventDetail`、`testImportedThingFixtureCanOpenThingDetail` | 已改为 App-owned 内置 fixture，走真实消息摄入/投影并点击 Tab、列表行、详情字段；不以 response/events 文件作最终 Oracle。Thing populated/empty UI 与快速 canonical-head patch 合同组合覆盖 tags/location/metadata/external IDs 的显示和显式清空，避免为每个字段复制设备 UI。 |
| keep（已迁移并扩成目的闭环） | `testEventClosePersistsAndOngoingFilterReflectsRealProjection` | 同一现有正向方法先取消关闭并要求详情仍 ongoing，再确认关闭；关闭载荷经正式通知解析与 canonical projection 更新，随后核对列表、仅 ongoing 筛选排除、Thing 关联详情、准确时间线以及普通 relaunch 后 closed/时间线保持且关闭动作不复活。Runtime marker 只负责准备归因，不能替代任一产品终点。 |
| keep（已迁移） | `testSettingsPageVisibilityUsesRealControlsAndPersistsAcrossRelaunch` | 同一条正向旅程从真实 Channels→Settings 入口同时操作 Events/Things 开关，验证两个入口真实减少且 Channels 仍可用、恢复后分别可达准确功能空态，并在关闭和恢复后分别 relaunch 核对持久化；替代 Runtime command/state 用例，没有新增设备启动或边缘方法。 |
| keep（新增目的级证据） | `testEncryptedMessageRecoversAfterConfiguringKeyAndSurvivesRelaunch` | 合成密文先经正式通知摄入进入 App-owned Store；用户从真实消息详情进入解密设置并保存匹配格式的合法 Key，最终核对原消息的准确标题/正文、成功状态和 relaunch 持久化。configured 标记、fixture marker 和密钥文件均不是终点。 |
| keep（新增代表性 a11y/l10n/动态导航证据） | `testSimplifiedChineseAtAccessibility5CompletesMessageDetailAndChannelCreation` | 先证明实际 SwiftUI Dynamic Type 为 accessibility5，并在真实 unread=1 下核对系统 Messages Tab 自己拥有“消息”标题和 badge、保留可点宽度、标题区域有可读像素对比度；再点击进入准确消息详情、填写真实频道表单并要求 accepted mutation 生成准确频道行。临时把生产 badge 改成 9 时精确红灯；资源全集由独立合同覆盖，物理 VoiceOver 仍单列。 |
| delete（已被更强旅程替代） | `testPushSettingsCanOpenDecryptionScreen` | 新解密旅程从真实 Channels→Settings 入口操作 invalid/valid key，核对成功状态、不回显、清除和两种 relaunch；仅打开页面不再进入常规 lane。 |
| delete（已被更强旅程替代） | `testInvalidServerAddressShowsInlineFeedbackInsteadOfToast` | 新 server 旅程同时覆盖 invalid 不 dismiss、标准化保存、数据换域和 relaunch；只验证错误呈现的弱重复已移出常规 lane。 |
| rewrite；由新核心旅程替代 | `testFixtureSeedMessagesRefreshesMessageList` | `testQualityStandardMessagesShowAccurateContentAndSurviveRelaunch` 已在同一次 App-owned 主链证明准确行/详情、生产 Open Link→Safari 展开地址栏后的精确 canonical path→返回同一准确详情、本地缓存图片真实解码→点击→生产预览/系统分享、搜索以及 relaunch；旧 seed count/state 用例应在后续删除。 |
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
| keep（已迁移） | `testSidebarNavigationCoversPrimaryScreens` | 同一 App-owned 会话由真实 canonical 101 未读产生 `99+`，先裁决“消息”标题不被覆盖且可点击，再经 macOS 已注册 `pushgo://` 打开准确 Message 与 Event/Thing 详情并真实点击 Sidebar 完成五域准确内容。 |
| keep（已迁移并扩成目的闭环） | `testEventDetailCloseAndRelaunchPreserveAccurateProjection` | 不新增方法或 App 启动；同一旅程验证取消无副作用、确认关闭、时间线更新、ongoing-only 筛选排除/恢复、Thing 关联详情同步、普通 relaunch 后 closed/时间线保持，最后删除当前 Event 并要求剩余控制事件的准确标题/摘要立即替换分栏详情。筛选缺失是真实产品缺陷；delete fallback 首轮即通过，归为证据补齐。 |
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
| keep（新增目的级证据） | `testClosingMainWindowKeepsAppRunningAndStatusItemRestoresOneFunctionalWindow` | 从准确旧消息发起正式 Provider Refresh，在 slow/in-flight 时关闭真实主窗口；要求进程继续运行、App 自有状态栏入口仍可达、恢复后仅一个窗口，且经正式 ingress 持久化的新消息精确正文与原控制消息同时可见。复用既有方法、fixture 与启动。 |

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
- `testHistoryCleanupRemovesOnlyOldMessagesAndPersistsAcrossRelaunch`（共享动态 fixture 只放 45 天目标与 2 天控制；iOS/macOS 各用 30 days 真实入口证明旧删新留、badge 2→1 和 relaunch，避免为六档复制 UI 测试）
- `testQualityMessageWorkflowLoadsSecondPageAndPersistsReadActions`
- `testMessageChannelTagCombinedUngroupedFiltersAndScopedReadPersist`
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
- `testChannelCreateRenameAndBothUnsubscribeOutcomesPersist`（同一次启动先经真实 Sheet 订阅既有频道，并要求准确行和 relaunch 保留；改名在同一受控 Sheet 内依次证明取消不改名、非法值/远端拒绝由 Sheet 自己显示且保留输入与旧行、同入口重试成功并跨 relaunch 保留，再继续两类退订。该扩展不新增 fixture、测试方法或 App 启动；复制反馈由独立 macOS 旅程覆盖，不重复等待瞬时 toast）
- macOS `testUnreadBadgeAndChannelLifecyclePersistThroughRealUserActions`（复用原 badge→读取→Channel copy 方法和唯一 relaunch；既有频道订阅先经历一次 typed 密码拒绝，要求错误只属于 Channel Sheet、ID 与密码字段保留、提交仍可用且没有脏行，再在同一 Sheet 重试成功；随后继续创建、菜单改名、保留/删除历史退订，并从准确 Channel 行、消息正文、生产删除期限、relaunch 和系统剪贴板裁决。没有增加默认方法或启动；当前回执 `build/quality-results/macos-channel-recovery-final/run-20260831-000123.xcresult` 为 1/1、108.202 秒、零重试）
- `testChannelRemoteRejectionStaysInSheetAndRetryPersists`
- `testChannelCreateLocalFailureCompensatesRemoteBeforeRetry`
- macOS `testSettingsPageVisibilityUsesRealControlsAndPersistsAcrossRelaunch`（复用原页面显隐旅程、fixture 和第三次既有 relaunch；末尾从真实 Settings Getting Started 控件交给系统默认浏览器，地址栏必须是准确安全 HTTPS host/path，返回后仍在同一 Settings。page×locale 全映射由 Core 快速合同负责，不新增测试方法、App 启动或页面×语言×浏览器矩阵；当前 1/1、100.450 秒、零重试，回执 `build/quality-results/macos-documentation-handoff/run-20260831-001201.xcresult`）
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

消息核心旅程进入 PR，其中 Apple workflow 用 125 条数据穿过三个真实 page-size=50 页段并核对准确首尾对象，再验证单条/全部已读、两阶段 relaunch 与未读筛选；新增控制行保持既有未读集合不膨胀。筛选旅程使用 5 条可手算 fixture，但 UI 只保留 `alpha+even` 精确交集、`ungrouped` 精确集合、当前作用域全部已读、全局 badge 4→3 与 relaunch；标准/legacy 标签解析与集合组合下沉低层，详情由独立 P0 旅程接管，避免三平台重复开弹层、重复详情和重复等待。刷新旅程分别证明慢态与上次准确快照共存、Provider 刷新载荷经过规范化摄入后出现在列表和真实详情并在 relaunch 后保留，以及首次失败可见、旧快照保留、同一正式刷新动作重试后恢复；不把直接修改 ViewModel 集合或检查数据库文件当结果。开发切片先跑 focused + 必要低层；Release 只在发布/里程碑汇总时运行，不能因单一 fixture 改动提前重复通知、Watch、全 Settings 和 100k 性能。其余真实导航、Entity、Channel 与 Settings 进入 Nightly/Release。Channel 创建补偿必须覆盖凭据/DB 中点失败、本地回滚、远端撤销、正式重载、重试和 relaunch；Server 同样既覆盖候选远端拒绝，也覆盖远端成功后的本地提交中点失败，且 rollback 自身失败不得静默。Decryption 必须覆盖存储失败后重启仍未配置、错误 Key 不产生明文、纠正恢复，以及损坏认证密文安全失败。

系统通知纵切独立成文件和 runner，只在 Nightly/Release 以及自身或通知相关产品代码变更时执行，避免普通 UI 测试改动无差别升级；开发者/AI 可用 `scripts/quality_test.sh system-notification` 做定向归因并生成双状态收据，但它不能替代影响计划要求的 Nightly/Release。宿主 readiness 文件只协调“App 已后台、可以注入”，不读取或写入产品数据库，也不参与产品通过判定；每轮由测试生成唯一 message id、标题和正文并通过原子 readiness contract 交给投递端，防止旧通知命中本轮 Oracle。默认 lane 的首条点击旅程以干净安装重新证明真实授权；后续冷启动/action 旅程保留这份已证明的系统授权，避免短时间连续卸载、重装和授权造成 SpringBoard 准备竞态，但仍各自建立独立 App-owned session、唯一 payload，并先确认宿主确实已安装。热启动与终止进程冷启动都以 SpringBoard 准确通知、真实 `UNNotificationResponse` 路由、详情字段、canonical 列表及重启后的已读持久化为 Oracle。冷启动使用仅 Debug 可解析、五分钟到期、显式关闭的 App-owned lease；Runner 不读取 App 数据库，Simulator 在用户点击前预唤醒 App 也不能把会话消费掉。Mark as read 旅程要求生产 action 保留准确 canonical、消除未读并在 relaunch 后保持；Delete 旅程要求 destructive action 删除目标，同时无关控制消息及正文不变、重启不复活。Simulator `simctl push` 证明系统边界但不等价于真实 APNs 网络；通知中心清理也不能用 App 前台时“SpringBoard 文本不可见”冒充，因此两者继续明确为 `NOT RUN`。

readiness 之前的 App-owned session、系统授权操作、后台切换和 Runner 临时目录写入统一标记为 `QUALITY_PRECONDITION`；失败时产品状态为 `NOT_RUN`、测试系统为 `BLOCKED`。readiness 之后的 SpringBoard 字段、点击/动作路由、详情、已读或删除结果、准确 canonical/无关控制对象和 relaunch 数据才是产品 Oracle，失败记 `FAILED`，防止准备问题与真实产品回归互相污染。

该纵切已有三类负控：把注入正文改错时，点击旅程在 SpringBoard 精确正文断言处失败；把生产 Delete action 故意接到 mark-read handler 时，删除旅程在 canonical 目标仍存在处失败；把生产 Mark as read action 故意接到 delete handler 时，已读旅程因目标 canonical 不再可操作而失败。三者均被 runner 归为产品 Oracle `FAILED`，恢复生产字节后必须再次全程通过，防止“有任意通知/按钮能点/通知 UI 消失”这种形式判定冒充内容、路由、已读或持久删除正确。

Quality session 不再只隔离 GRDB：server config、decryption material metadata 与手动编码偏好由 App 自己的 session `config` 目录持有，同 session relaunch 可读、不同 session 不共享，生产 Keychain/gateway token/fallback 不读不写。配置文件损坏或权限错误必须阻断 readiness，不能被默认值伪装成成功。首次完整 Release 的 2/18 失败正是该隔离缺口的负控证据；结构修复后定向 3/3 与完整 18/18 均通过，原失败结果包继续保留。

Store fatal recovery 风险方法不再只证明错误页与普通退出：同一方法先建立真实 canonical 数据，保留第一次失败时 destructive action 不应出现及安全退出，第二次失败才点击生产 rebuild，并要求 App 完成删除后退出；同 session 普通重启必须进入可用空列表且旧 canonical 行不复活。Quality Runtime 只把生产 3 次门槛压缩为 2 次准备，不替代真实 Store、UI、删除或重启；0 阈值在 decoder 边界拒绝。主库/index/legacy 及 SQLite sidecar 完整删除由独立 Store 测试对账。该方法仍只属于 iOS/macOS Nightly/Release risk 集，不进入 PR/positive。no-op destructive Store 反例最终在 iOS 普通重启后的空态终点精确失败；正式实现恢复后 iOS 1/1、41.627 秒与 macOS 1/1、28.919 秒均零业务重试通过，Core 聚焦 24/24 通过。Alert 动作由 semantic ID 优先、固定英文可见按钮兜底；macOS 可见节点限定到 sheet，避免同名不可点击节点。容量阻断、Problem Reporter 清理阻断和接入错误均保留为测试系统证据，不能被最终绿色改写；Simulator lease 已释放。

## 变更影响门禁

`config/quality-impact.json` 把当前产品源码分配到 Messages、Entity、Channel/Settings、Ingress、系统表面、Watch、App shell、共享 UI/媒体、Performance 和 Release 等具名能力。`scripts/quality_changed.sh` 先执行选择器负控，再运行不低于推荐值的真实 Lane；独立性能测试/runner 变更选择 `performance`，与产品规则同时变化则提升到同时执行功能和性能的 `release`。新产品路径未映射时直接 `BLOCKED`。这只是确定性下限，不能替代对 caller、Store、错误分支和平台消费者的语义追踪。

PR 的固定设备预算现只投向 4 条最高密度正向链：`core.positive` 跨域核心旅程、标准消息 migration/media/search/relaunch、分页/已读持久化、Gateway 候选注册→切换→换域→relaunch。`core.positive` 不是空页面矩阵：同一个 App-owned Store 通过正式摄入提供 Message、Event、Thing 和 Channel，并以 99 条较旧 canonical 控制消息把真实未读推到 101，但不挤走原准确首行；两端先要求 `99+` 且 Messages 标题仍可读/可点，再完成各自原有准确五域目的。最终当前字节 iOS 1/1、76.712 秒（`build/quality-results/ios-high-unread-final-sorted/run-1-20260830-195745.xcresult`），macOS 1/1、51.562 秒（`build/quality-results/macos-high-unread-final-sorted/run-20260830-195950.xcresult`），均零重试；相对最近同主链合计增加约 14.64 秒，没有新增方法或启动。其余 9 条正向生命周期组成 `extended_positive_ui_scopes`，继续保护历史清理、Markdown、筛选、刷新、Event relaunch/filter、Thing 三关系/删除/relaunch、Channel 全生命周期、页面显隐和解密恢复；它们在里程碑正向聚合或 owner 变更 focused 执行，未被删除，也不从跨域 Smoke 外推。正式 `scripts/quality_test.sh ios-positive` 只执行 13 条 App-owned 正向旅程、强制零业务重试并生成独立六态收据；最近完整 13/13 仍为 789.524 秒（`build/quality-results/ios/run-1-20260830-074151.xcresult`），本次 focused 不追溯改写该历史聚合。15 条风险/故障 scope 未被选择；Nightly/Release 仍先完成正向并记录 claim，再启动故障、损坏和补偿集。静态合同锁定 4/13 分层、`ios-positive` 不得引用风险集合、scope 唯一可发现和正向先于负向。

macOS Runner 不再把 App-owned 正向、故障旅程和真实系统边界无差别作为普通默认：`positive` 集为 16 条，优先覆盖首次使用、准确内容/Markdown、筛选/清理、频道生命周期、删除 Undo→恢复→再次删除→提交的完整正向生命周期、慢加载/慢刷新预警、窗口恢复、主导航、Event/Thing、Settings/Decryption 正常生命周期和 Gateway 正常切换；`risk` 集为 9 条，承载 Store 初始化失败、加载/刷新/Event 失败、受保护写失败、错钥匙/坏密文、非法地址和 Gateway 本地提交补偿；`system` 集仅 1 条真实 Notification Center 点击→准确详情→持久化→relaunch 正向旅程。独立 `macos` Lane 默认只跑 `positive`，Nightly 跑 `full=positive+risk`，Release 在正向优先顺序中额外执行一次 `system`；开发者/AI 可用 `scripts/quality_test.sh macos-system-notification` 定向执行。静态合同要求 16/9/1 三集合互斥且并集精确等于全部 26 条可发现旅程；系统旅程不进入 PR、普通 macOS 或 Nightly 固定成本，也不能从这些 Lane 的绿色外推。

本机 PushGo 通知权限开启后的 macOS 27 新鲜证据进一步划清了系统边界：唯一标题/正文已真实出现在横幅和通知中心，说明授权与调度完成；但通知卡片没有 XCTest AX 节点，XCUICoordinate 与 HID event 都未产生 `UNNotificationResponse`。两种替代输入收敛后停止，不继续增加坐标、等待或重试。当前 `macos-system-notification` 因而必须输出产品 `NOT_RUN`、测试系统 `BLOCKED`、`apple-quality-precondition`，而不是把视觉出现判为功能通过，也不是误报 App 产品失败。未来只有稳定可操作的系统节点或 Apple 提供的受控通知消费者出现后才恢复这条链；低层/App-owned response 合同不能替代真实系统点击。

macOS 状态栏只保留真实产品语义：左键恢复主窗口，右键提供 Open Main Window 与 Quit。既有窗口正向旅程现于正式 Refresh slow/in-flight 时关闭主窗口，真实右键并点击本地化 Open Main Window，核对唯一窗口、同一 App-owned session、准确新旧消息，再次关闭并用左键恢复；1/1、29.132 秒、零重试。未挂载的 `MacMenuBarContentView` 及其用 `try?` 把数据库失败伪装为空态的 `MenuBarViewModel` 已删除，不再用死代码制造菜单栏未读“覆盖”。Quit 会终止测试主体，保留为受控 Release/人工动作，不以菜单项存在判通过。

macOS 标准消息正向方法同时承担最低充分的 migration UI：App 在隔离容器构造 v17 旧行后由普通 `GRDBStore` 正式迁移；同一方法核对旧标题/正文详情、新消息/图片预览共存以及唯一 relaunch 后两者都保留。它没有增加 discoverable 方法、fixture 名或启动次数，新增约 3 秒交互，替代单独的平台迁移方法；历史版本逐一升级、损坏库与 Watch 独立 Store 不从该代表例外推。

## 设备测试价值/成本审计与止损

当前设备预算先证明“用户能否完成主要目的”，而不是先穷举所有失败姿势。日常开发默认只跑影响选择得到的 focused + 必要低层；Apple PR 固定为 iOS 4 条高密度核心正向；需要完整产品正向信心但不需要故障注入时，使用 iOS 13 条 `ios-positive`、Android 完整正向和 macOS 16 条 `macos`；只有 Nightly/Release 或对应风险 owner 变更才追加风险集合。四条 PR 不是把全部深度压成 Smoke：跨域核心负责广泛可用性，另三条分别承担迁移/媒体/搜索、分页/已读持久化和高风险 Gateway 事务；Event/Thing/Channel/Settings 的深层生命周期仍由扩展集保留。空态、搜索等能被同 fixture 同启动证明的结果已经合并；六个清理档位、重复的单字段组合和对称第三次启动不复制成设备用例。

用例进入日常正向集合需同时满足三点：它保护尚未由其他旅程证明的真实用户目的；最终 Oracle 是准确功能/数据/持久化结果而非文件、版本或控件存在；它不能以更低层合同或并入现有旅程的方式同等证明。新增能力默认先尝试复用已有 fixture、同一进程和既有 relaunch；若只是增加一个元素存在断言、重复相同存储机制、或只验证测试接入点，拒绝进入设备 Lane。测试 ID 只负责定位，不计作覆盖收益。

负向与边缘场景不再与正向覆盖争抢日常预算。只有可能造成数据损坏/丢失、错误成功态、未验证即覆盖旧配置、崩溃、安全问题，或已经发生过高价值事故的反例，才保留阻断性风险证据；其余失败注入、权限拒绝、损坏输入、对称撤销、导入/试听失败和系统组合放入 Nightly/Release、owner 变更时 focused，或明确 `NOT RUN`。慢加载与慢刷新虽不是普通 happy path，但对应已发生的“数据很慢却未预警”事故，所以作为少数例外保留在 macOS 正向集；它们同时要求预警及时出现和最终准确数据到达，不能只看 loading 标志。

执行时采用明确止损：同一测试接入障碍若连续两种独立操作方式都不能形成稳定的用户结果 Oracle，就停止消耗设备时间，回退未证实改动并登记为测试系统/接入点缺口；不得靠重试、sleep、测试专用业务 UI 或降低断言硬闯绿色。2026-08-29 的 macOS 通知声音候选即按此规则退出：真实 Sheet 可达，但 AppKit 原生 `Menu` 的弹出项无法被当前 XCUI 栈稳定查询或驱动，四次零重试聚焦运行均停在选择结果仍为 `None`；相关未完成代码已全部撤回，能力继续保持未覆盖，而不是占用日常 Lane 或虚报通过。后续只有在产品提供自然、可访问且不为测试专设的稳定交互语义时才重开。

每轮扩面按“新增用户目的数 / 新增设备启动与运行时间”复核。优先级依次为：尚未覆盖的 P0 正向目的；已发生事故且能同时验证预警与最终结果的 P0/P1；数据安全事务反例；普通错误恢复；低频平台/输入组合。前两级未完成时，不主动扩展后两级。完整 discoverable 集仍由静态合同与 Nightly/Release 并集守住，延期必须显式记录，不能通过从 Runner 静默删除获得提速。

### macOS 更新安装：一个 P0 正向纵切替代多层形式检查

更新能力不再只凭 Appcast、版本号或文件存在宣称可用。专项 `macos-update-install` 使用临时本地 feed 和每轮临时 Ed25519 材料构建旧/新两个 DMG 版本；用户路径从旧版 Settings 的正式 Check for Updates 开始，随后要求 Sparkle 对签名包完成下载和 sandbox 安装、原安装路径中的 bundle 被替换、新 PID 从同一路径自动重启、App-owned quality session 恢复，最后在真实 Settings 看见新版本。整个业务动作只执行一次、业务重试为 0，不把 HTTP readiness 的有界准备轮询算作产品恢复。最新证据为 `build/quality-results/macos-update-install/20260830-005007/evidence.json`，总入口双状态收据为 `build/quality-results/apple-macos-update-install-summary.json`；1/1 通过，本次复用构建缓存的端到端总时长 18 秒。

首次真实执行发现两个之前静态元数据契约无法发现的发布缺陷：sandboxed DMG 缺少 Sparkle installer launcher 开关和 `-spks`/`-spki` mach lookup 权限；仓库 xcconfig 又给公钥值保留了字面引号，导致本地/Fastlane 生成的 enclosure 没有 EdDSA signature。实现现按 [Sparkle 官方 sandbox 集成要求](https://sparkle-project.org/documentation/sandboxing/)补齐 launcher 与最小 mach 权限，并让公钥以合法 32-byte base64 进入构建；静态校验保留为便宜的 PR 前置，但只有真实专项旅程可以完成“可安装”的声明。

该旅程构建两个 DMG target 的 hermetic Debug 版本，覆盖收益高但固定成本不适合日常：只由独立 Lane 和 Release 调用；PR 仍只跑毫秒级元数据/集成合同，Nightly 与普通 `macos` 明确记录 `NOT_RUN`。静态成本合同阻止它被误塞回三个常用 Lane，同时锁定一次检查、一次安装、零业务重试。它证明 Sparkle 真实安装集成，不证明线上生产签名+公证 archive；后者与 App Store 客户端安装仍是外部受控缺口，不能由本旅程绿色外推。

计划中的 `required_checks` 是必须实际执行并写入收据的补充证据：Appcast/App Store metadata 使用快速语义契约，不启动完整 Release；Fastlane/构建/隐私/回滚变更强制执行发布静态契约并保持 Release Lane。两端各 120 次历史回放已校准旧路径漏选；无效或未知计划直接 `BLOCKED`，不回退为默认绿色。

## Test-system/flake 处置

`config/quality-test-system-issues.json` 取代 runner 内不可审计的“已知失败”口头清单。App-owned 准备失败由 0 重试的 `apple-quality-precondition` 归因；签名、owner、到期日和退出条件均由 `quality_test_system_issues.py` 校验。原 `apple-simulator-xctest-runner-launch` 在 50/50 App-owned 功能启动后已 resolved，通用 iOS Runner 不再允许一次隔离重跑；新的 Test Case 前未知 Runner 故障直接 `BLOCKED`，产品断言仍为 `FAILED`。完整规则见 `docs/quality/test-system-issue-governance.md`。

四个 100k/Watch/concurrency 重型用例已从函数内提前 return 改为框架条件禁用；日常输出必须显示 skipped，并在结果 `not_run` 中列出。`scripts/quality_test.sh performance` 先用 doctor 的 `--host-only` 模式执行 `RuntimeQualityLargeScaleTests`，再在专用 Simulator 执行独立文件 `PushGo_iOSPerformanceTests.swift` 中的 `testPreparedLargeMessageStoreColdLaunchReachesAccurateContent`：数据准备在测量区间外，5 次正式样本采集 launch/clock/CPU/memory，测试端完整启动到准确首行不得超过 8s，最后必须打开相同 persisted body。该 8s 只防 Simulator 明显退化。显式提供参考设备 ID、准确 sentinel 与设备预算时，同一 Lane 继续调用 `scripts/run_ios_physical_performance.sh`，在 Release 配置固定真机执行 10 次；缺条件保持 `NOT_RUN`，不得回落到个人真机或 Simulator。Release 是功能与性能共同超集。ETTrace 仅在指标失败后临时接入做归因，不作为生产或常驻测试依赖。

## macOS 窗口生命周期验证与攻击记录

- 根因归因：状态栏左键与菜单动作都只调用 `showMainWindow()`；旧实现仅持有弱引用并查找现存窗口，既没有保证 close 后窗口仍被保留，也没有在最小化时显式恢复，因此“关闭/最小化”与“窗口不存在”被错误地当作同一状态。
- 实施：`MacMainWindowPresenter` 强持有唯一主窗口、设置 `isReleasedWhenClosed = false`、按固定 identifier 接管丢失 capture 的窗口，并在聚焦前显式 deminiaturize。AppDelegate 的状态栏按钮增加稳定、可访问的产品级 identifier；UI 用例最终仍看唯一窗口和同一 Store 功能态，不以 identifier 本身作为通过终点。
- 负控：临时删除 `makeKeyAndOrderFront` 后，关闭恢复测试在 `window.isVisible` 精确失败，最小化测试在调用次数精确失败；恢复实现后 3/3 通过，证明 Oracle 对“找到了窗口但没有真正显示”敏感。
- 集成攻击：首次 `build-for-testing` 发现新文件只进入 SwiftPM、未进入 Xcode macOS Sources phase；组件测试绿色不能掩盖产品未集成。补齐工程 membership 后 macOS App + UI target 构建通过。
- 测试系统归因：历史授权失败发生在测试方法进入前，因此当时正确记录为 `BLOCKED/NOT RUN`。授权恢复后，受控签名 Runner 的关闭→状态栏→唯一窗口旅程已升级为关闭期间在途 Provider 结果不丢失，并在当前字节 focused 1/1、23.397 秒、零重试通过（`build/quality-results/macos-ui/run-20260829-213145.xcresult`）；既有二十二条正式核心旅程仍由先前零重试 22/22 结果包 `build/quality-results/macos-ui-22-final/run-20260829-130358.xcresult` 证明，后续测试源码变化只使本条受影响证据需要刷新，不虚构整批已重跑。
- 崩溃归因：主导航首次真实执行发现 Message `HSplitView` 切换到 Event/Thing `HSplitView` 会在 AppKit `SplitViewChildController` 约束更新循环中崩溃。固定 300pt 列本就不提供用户可调语义，故三个页面统一改为 `HStack + Divider`；对象优先和完整往返导航均通过。页面级 identifier 另改为独立 1×1 语义标记，避免覆盖后代业务元素。
- 系统入口高密度正向切片：Widget、快捷指令、Spotlight/User Activity 最终共用 `PushGoSystemOpenTarget`，因此没有为每个系统表面复制一套设备用例，而是在两端既有主导航旅程内调用真实已注册 `pushgo://`：必须打开 fixture 中准确 Message 正文，再分别落到 Event/Thing 列表，随后继续原五域旅程。首轮 iOS 精确消息通过但 Event 列表失败，归因为系统目标在根视图监听建立前写入、初始选择未消费列表；共享 controller 也未完整清理旧目标。修复为“最新系统目标替代旧目标”并由两端初始导航消费 pending list。恢复后又删除了后半程重复打开同一 Message 详情的低收益步骤，只保留真实 Messages 控件→准确列表/行终点；最终 iOS 1/1、55.144 秒（`build/quality-results/ios/run-1-20260830-050356.xcresult`），macOS 1/1、42.227 秒（`build/quality-results/macos-ui/run-20260830-050516.xcresult`），均零重试，较未去重版本分别再省 5.682 秒与 1.778 秒。macOS 实跑还发现常规 App plist 未注册 scheme、只有 DMG 注册；现两种包均由语义合同要求包含 `pushgo`。这只证明共享外部路由终端，不外推 Siri、Widget 或 Spotlight 系统 UI 已通过。
- Runner 卫生：正式 `scripts/run_macos_ui_tests.sh` 零重试，26 条可发现旅程全部被静态合同精确分入 16 条 `positive`、9 条 `risk` 与 1 条 `system`；普通 macOS Lane 只跑正向，Nightly 跑 App-owned 正向后风险，Release 再独立执行真实系统边界，防止新增能力被静默漏跑或把系统成本塞回日常。Apple PR 另只选择一条约 38 秒的 macOS `core.positive` 代表：同一次启动核对 unread 下“消息”标题与 badge 的可读/几何/对比度/点击终点，并打开准确 Message/Event/Thing、Channel 和 Settings；它不把 16 条完整正向集全部变成日常固定成本。删除 Undo 与 deadline 提交不再各付一份 fixture 和 relaunch：同一正向旅程以两个 canonical 对象先证明恢复，再证明提交和非目标不受损，最后一次 relaunch 同时裁决两者；当前字节 1/1、39.275 秒、零重试（`build/quality-results/macos-ui/run-20260830-002045.xcresult`），较原两条当前字节 55.562 秒节省约 29% 且少两次 App 启动。Runner 先通过 `IOConsoleLocked` 证明交互桌面已解锁，并在生命周期持有 `caffeinate` 防止长批次中途空闲锁屏；锁屏直接归测试系统 `BLOCKED`，不再误报产品激活失败。XCTest 在每条旅程的 `setUp/tearDown` 终止本用例启动的 App，并在前后各观察一个安静窗口、关闭 bundle id 精确匹配的系统 `Problem Reporter`；外层 Runner 另在整批开始前、结束后及中断/退出时按系统可执行路径精确清场，且测试期间每 200ms 持续监控延迟出现的新窗口，无法关闭同样归 `BLOCKED`。因此某条崩溃仍保留产品 `FAILED`，但弹窗不会遮挡后续旅程。明确 `QUALITY_PRECONDITION` 的 App-owned readiness、系统权限与桌面切换失败由共享注册表归产品 `NOT_RUN` / 测试系统 `BLOCKED`；已开始的可见字段、系统点击、准确详情或 relaunch Oracle 失败才是产品 `FAILED`。本轮真实权限拒绝负控结果包为 `build/quality-results/macos-ui/run-20260830-081814.xcresult`，正式收据为 `build/quality-results/apple-macos-system-notification-summary.json`。
- macOS 启动治理不从普通批次偶然绿色外推。opt-in `scripts/run_macos_startup_reliability.sh` 构建一次后执行 50 个预先计划的独立 XCTest invocation；每轮新 App-owned `empty.clean` session 必须完成准确空态、Settings→Messages 真实导航往返及最终准确空态，外层持续清理崩溃窗但不重试业务。XCTest repetition 曾稳定复现 `Running Background` 激活共模故障，故不再用于 macOS campaign；独立 invocation 最终 50/50、双状态通过、零 issue/激活故障/业务重试，p50=16.163s、p95=16.378s。少于 50 轮只标 calibration，不能满足退出条件；该治理波次不进入普通 PR。
- Apple 本机交互门禁：`scripts/require_unlocked_apple_ui_console.sh` 现由 macOS、iOS Simulator 与 watchOS Simulator 三个正式 UI Runner 共用；锁屏时三者都在启动构建/模拟器和任何产品动作前退出 2、写入 `BLOCKED`，并分别报告 `macos`、`ios_simulator`、`watchos_simulator` 原因。当前真实锁屏负控三入口均精确命中；共享门禁及三个 Runner 也由影响选择器纳入 `quality-system-trustworthiness` 的 PR 证据，不再被脚本忽略规则归为 `NOT_RUN`。
- 数据加载纵向样板：App-owned standard 数据验证真实行的准确 title/body 语义、真实详情和进程重启持久化；8 秒受控延迟必须先显示 slow 提示再进入准确空态；首次失败必须显示真实错误并由可点击 Retry 恢复。初版标准数据 Oracle 错把 VoiceOver 合并行当作 `staticTexts`，首轮精确失败后改为校验真实行的 label/value，详情根 identifier 也拆为独立 marker，避免吞掉详情内容。
- 刷新产品缺口：macOS 原 `.refreshable` 无显式入口且丢弃 Provider outcome，旧数据继续显示会掩盖慢/错。现增加真实 Refresh 工具栏按钮、慢态和 Messages-owned 失败态；失败保留原准确行，同入口 Retry 写入并打开准确新详情，relaunch 后仍存在。临时移除 slow marker 的负控在预警 Oracle 精确失败，恢复后 focused 2/2。
- Event/Thing 目的链：Event 用例核对准确行与详情，确认关闭后必须看到真实 canonical projection 变为 closed、动作消失并跨进程保留；Thing 用例用同一二对象 fixture 先精确删除干扰项，等待生产 deadline 并 relaunch，随后要求删除项不复活、控制 Thing 的 identity/summary 与三个关系页签/详情仍准确。它没有增加测试方法或启动，且不把删除按钮、pending bar 或 identifier 当最终 Oracle。真实执行先暴露并修复关系行点击区域不触发、三个并列 Sheet 状态所有权，以及 Event projection 丢弃 canonical body 三个产品问题。
- 红蓝与双向反查：将关闭回送的 `event_state` 临时从 closed 改为 active 后，用例在 `field.event.detail.status.closed` 的业务终点精确失败（`build/quality-results/macos-ui-event-negative/run-20260829-004716.xcresult`）；恢复后 focused 1/1 与默认 12/12 通过。source→test 覆盖 close action/delivery/persistence、Thing 三关系导航与 Event body fallback；test→product 每个最终 Oracle 均落在准确用户可见数据、可操作性或 relaunch 持久化，不以文件、版本、identifier 存在作为通过终点。
- Gateway 当前证据：候选注册拒绝→Sheet owner→不覆盖旧地址→重试成功→旧数据换域→relaunch 与 commit 中点失败→即时/重启回滚→重试后才换域均 focused 通过，同进程聚合 2/2 通过，并进入当前默认十八条。首次 commit 旅程因 65 字节测试会话 ID 超限正确归为 `FAILED_TEST_SYSTEM`；缩短并在 launch 前执行同合同校验后通过，未放松产品 Oracle。临时把 production candidate prepare 替换为常量、绕过注册时，用例精确失败于“拒绝必须留在编辑器”；恢复真实 prepare 后同例 1/1 通过，负控与恢复结果包分别为 `build/quality-results/macos-ui-gateway-bypass-negative/run-20260829-094611.xcresult`、`build/quality-results/macos-ui-gateway-bypass-restored/run-20260829-094735.xcresult`。
- 页面可见性当前证据：真实 Events/Things Toggle 同时关闭后两个导航入口立即消失、Channels 仍可完成导航，第一次进程重启仍隐藏；同一控件恢复后分别可达 Event/Thing 的准确功能空态，第二次重启仍可达。扩面没有新增测试方法或启动；当前字节 iOS 1/1、macOS 1/1、Android 1/1，全部零重试。首轮英文文案失败被归因为宿主中文环境，业务旅程固定英文后通过，本地化由专门任务独立承担。早期 macOS 外层 group identifier 覆盖三个子按钮及持久化写错值负控仍分别证明动作可达性和首次重启 Oracle 有效。
- 解密当前证据：真实 Settings 生命周期、受保护写失败与重试、错 Key→正确 Key 恢复、坏密文安全失败四条 4/4 零重试通过（`build/quality-results/macos-ui-decryption-final-four/run-20260829-104646.xcresult`）。用例以 Sheet 排他错误、准确配置状态、同一 canonical 消息的精确标题/正文与 relaunch 为终点；wrong-key 是反例，corrupt+matching-key 是安全变形。首轮同时归因掉敏感辅助 value 不暴露正文及中文输入法候选字两个测试系统问题，并真实发现“列表已恢复、详情仍旧 seed/cache”；移除 seed 快捷路径、按 Store revision 同步并重建详情身份后修复。预修复证据为 `build/quality-results/macos-ui-decryption-input-fixed/run-20260829-103508.xcresult`。

- 用户可见秘密不再以“SecureField 类型存在”求绿：Gateway Token 和消息解密 Key 均被并入原有目的旅程，必须默认遮蔽、显示后逐字等于输入、再次遮蔽，并继续完成保存/拒绝/清除、业务数据结果和 relaunch。APNs/FCM 注册 token 没有用户编辑/揭示入口，明确不纳入这条 UI 结论。iOS Gateway 旅程真实发现显示 Token 后系统“保存密码？”弹层覆盖 Sheet；产品把 app-scoped secret 从网站密码自动填充语义中移除后，完整旅程 1/1 通过。iOS 解密通过保留在首次 2 条批次中，macOS 两条同语义旅程 2/2 通过；本切片没有新增测试方法或额外默认 App 启动。运行器继续强制单 worker、禁止 Simulator clone，并在普通批次关闭失败后的昂贵 `simctl diagnose`；失败断言和完整 xcresult 仍保留，发布级专项才单独收集深诊断。
- Event 失败恢复当前证据：iOS/macOS 用同一状态机 `ongoing → closing → rejected/ongoing → closing → canonical closed → relaunch closed`，首次拒绝不丢准确详情，错误留在详情 owner，提交中动作不可重复；重试只通过 production-shaped delivery 与正式持久化更新 canonical。真实执行发现并修复 quality scenario 误落入密码前置分支、macOS `active` 被误判 unknown、iOS 条件替换工具栏仍可点击三类产品/集成问题。临时删除 iOS `.disabled(isClosing)` 后，用例在防重复 Oracle 精确失败（`build/quality-results/ios/run-1-20260829-124750.xcresult`）；恢复哈希与通过版本一致。2.5 秒仅是 Debug 故障注入可观察窗口，不是性能证据。
- 同上下文红蓝审查：实现、归因与审查仍由同一上下文完成，保留 `common-mode-risk`；当前默认 scope 包含二十二条明确旅程并已零重试 22/22，但不扩张到 Thing 筛选/深链/删除、通知、性能、真实 Gateway 网络或物理可访问性。

## watchOS 真实 UI 迁移、归因与攻击记录

- 迁移边界：旧 `PushGo-watchOSAutomation` 已删除；新 `PushGo-watchOSUITests` 由 App 根据 profile/scenario/session 自行准备隔离 Store，Runner 不写 App 容器。历史报告里的旧脚本命令仅是归档证据，不再可执行，也不能声明当前 UI 功能通过。
- 目的级 Oracle：同一真实会话核对两条 Message 的准确标题/正文/严重度，打开详情并分别验证取消与确认删除；确认后必须自动离开已删除详情，重启后删除仍成立。随后通过真实 Tab 手势核对 Event 与 Thing 的列表/详情、状态、正文和属性键值。测试 ID 仅负责可靠定位，不作为最终通过条件。
- readiness 与归属负控：不支持的 App-owned scenario 必须在 UI 明确显示启动失败和准确原因，不允许回退为空列表或生产数据。另用 Store 层消息读取故障证明错误只停留在 Messages，Event/Thing 仍能打开准确对象；Runner/Simulator 无法启动归为 `BLOCKED`，已进入但用户结果错误归为 `FAILED`。
- 产品归因：首次真实旅程先发现删除写入成功后仍滞留在已经不存在的详情页；修复为目标从 Store 消失后清理导航路径。随后发现 Thing 属性只展示原始 JSON、用户无法辨认字段；改为正式解析后的 key/value 行。三类列表此前也会把 Store 错误误报为空态，现统一显示错误与真实 Retry。
- 负控证据：修复前的真实运行分别在“删除后应返回列表”和 `region=eu-west` 可见字段处精确失败；滚动可见性问题只增加有界手势，没有给断言加重试或降低字段要求。错误归属反向审查又先让严格但偏题的内部故障文案 Oracle 失败，随后保留“错误可见、Retry 可操作、其他域任务准确”的目的级判定。最终代表套件 3/3 通过；最终 Lane 结果以本轮新结果包为准。
- Release 隔离：Hermetic runtime 全部受 `#if DEBUG` 限制；影响规则将 watch runtime/AppEnvironment 提升到 Release，Release Lane 同时构建 iOS 与 watchOS，防止调试测试入口污染正式产物。
- 当前处置（2026-08-30）：四个正式旅程按 scope 独立运行，构建产物先显式安装并验证 App container 可观察；`installcoordinationd` 卸载/placeholder 导致的 LaunchServices nil 仍属 `BLOCKED`，不是产品失败，也不允许自动重跑。专用 `PushGo Quality Watch` 最终当前字节核心旅程 1/1、零重试、44.405 秒，并以真实业务标题停止 Event/Thing 分页。Receiver 的完整失败树先证明标准 App-owned 场景实际为 `Needs sync`；该场景没有 provisioning、频道订阅、APNs token 或 transport 成功，所以撤回了强制 `Ready` 的假绿方案。最终同一核心旅程要求 `Needs sync`、拒绝 `Ready`，并实际滚动到三段精确说明正文；Debug hermetic 启动不再激活 WCSession 或生产 reconcile。受影响 Watch 类 4/4、72.435 秒（`build/quality-results/watchos-hermetic-final/run-20260830T082917Z.xcresult`）；migration 旅程仍只在 Nightly/Release Watch 组执行。历史 Apple Release 总结保持当时状态，focused 不能追溯改写；真实 Receiver Ready/等待频道/鉴权失败/恢复、物理通知与 complication 继续 `NOT RUN`。
- 同上下文红蓝审查：实现、失败归因、修复与本轮审查由同一上下文完成，仍有 `common-mode-risk`；因此只声明代表性 Messages/Event/Thing 链路和 Receiver degraded 状态真实性，绝不外推 mark-read mirror ACK、图片/解密、真实 Receiver Ready/恢复、物理通知/complication、VoiceOver 或字号矩阵已经通过。
- 2026-08-30 成本收敛：源码与提交历史确认当前 iPhone 控制、新安装和 Watch 控制上下文均强制 `standalone`，设置页也无模式切换；遗留 mirror generation/action 只保留为旧版本兼容候选，不再进入日常 P0 UI 预算。核心旅程复用原 session/fixture 增加“第二条消息初始未读→打开后未读标识消失→进程重启后仍已读”，未新增测试方法或启动。`run-20260830-031407-2022.xcresult` 已执行并通过该新增重启后 Oracle，后续既有 Event 详情导航未完成；最终尝试 `run-20260830-032343-4498.xcresult` 被 runner 准确归为 `BLOCKED: watchos_app_install_launch_race`，不得记为产品失败或全绿。Watch runner 同时增加每个测试 120 秒硬超时，防止启动挂死无限占用预算。
- 2026-08-31 行语义收口：没有新增测试方法、fixture、App 启动或 Lane。Message/Event/Thing 的生产 `NavigationLink` 现在各自拥有稳定 row ID、对象标题 label 与业务 value；现有核心旅程必须从这些真实按钮读取 Message 的读状态/严重度/正文、Event 的生命周期/严重度/摘要、Thing 的业务摘要，确认 hittable 后进入准确详情，并继续证明 Message 阅读状态跨 relaunch。核心 1/1、45.352 秒；其余 Watch 旅程 3/3、29.935 秒，零跳过/零业务重试。该证据只关闭 simulator semantic mapping；物理 VoiceOver/字号任务仍明确 `NOT RUN`。
