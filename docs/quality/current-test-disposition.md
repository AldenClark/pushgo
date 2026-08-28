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
| keep（已迁移） | `testImportedEventFixtureCanOpenEventDetail`、`testImportedThingFixtureCanOpenThingDetail` | 已改为 App-owned 内置 fixture，走真实消息摄入/投影并点击 Tab、列表行、详情字段；不以 response/events 文件作最终 Oracle。 |
| keep（已迁移） | `testEventClosePersistsAndOngoingFilterReflectsRealProjection` | 从真实 Event 行进入详情并确认关闭；关闭载荷经正式通知解析与 canonical projection 更新，验证状态变为 closed、仅进行中筛选排除该事件、重启后 closed 仍保留且关闭动作不再出现。Runtime marker 仅用于启动归因，不作为产品 Oracle。 |
| keep（已迁移） | `testSettingsPageVisibilityUsesRealControlsAndPersistsAcrossRelaunch` | 从真实 Channels→Settings 入口操作 Event 开关，验证 Tab 真实减少/恢复、恢复后可打开准确 Event 页面，并在关闭和恢复后分别 relaunch 核对持久化；替代 Runtime command/state 用例。 |
| keep（新增目的级证据） | `testEncryptedMessageRecoversAfterConfiguringKeyAndSurvivesRelaunch` | 合成密文先经正式通知摄入进入 App-owned Store；用户从真实消息详情进入解密设置并保存匹配格式的合法 Key，最终核对原消息的准确标题/正文、成功状态和 relaunch 持久化。configured 标记、fixture marker 和密钥文件均不是终点。 |
| delete（已被更强旅程替代） | `testPushSettingsCanOpenDecryptionScreen` | 新解密旅程从真实 Channels→Settings 入口操作 invalid/valid key，核对成功状态、不回显、清除和两种 relaunch；仅打开页面不再进入常规 lane。 |
| delete（已被更强旅程替代） | `testInvalidServerAddressShowsInlineFeedbackInsteadOfToast` | 新 server 旅程同时覆盖 invalid 不 dismiss、标准化保存、数据换域和 relaunch；只验证错误呈现的弱重复已移出常规 lane。 |
| rewrite；由新核心旅程替代 | `testFixtureSeedMessagesRefreshesMessageList` | `testQualityStandardMessagesShowAccurateContentAndSurviveRelaunch` 已证明准确行/详情/relaunch；旧 seed count/state 用例应在后续删除。 |
| rewrite | `testSubmittingPopulatedSearchResultsKeepsAppRunning` | “App 仍运行”过弱；改为目标集合、排除集合、最新 query 和打开准确详情。 |
| rewrite | `testFixtureSeedEntityRecordsPublishesProjectionCounts`、`testFixtureSeedSubscriptionsPublishesImportState` | 改为真实 Event/Thing/Channel 内容与后续操作；内部 count 只诊断。 |
| delete（已被更强旅程替代） | `testSettingsPageVisibilityCommandCanHideEventPage`、`testSettingsPageVisibilityCommandCanRoundTripEventPage` | `testSettingsPageVisibilityUsesRealControlsAndPersistsAcrossRelaunch` 已覆盖真实入口、动作、准确页面和双向 relaunch；旧 command/state 不再进入常规 lane。 |
| rewrite | `testEntityOpenPublishesEntityStateAndProjectionCounts`、`testMessageOpenPublishesMessageDetailState`、`testNotificationOpenPublishesMessageDetailState` | 用真实列表/通知路由打开，核对目标对象和字段；Automation State/Event 不再是最终 Oracle。 |
| rewrite | `testNotificationMarkReadCommandUpdatesUnreadState`、`testNotificationDeleteCommandUpdatesCounts` | 通过真实通知动作；对账通知、Store、列表、badge 和 relaunch。 |
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

## 已确认的首要缺陷模式

1. iOS Runner 把 Fixture、response、state、events 的宿主绝对路径传给 App；最终结果大量读取这些文件。
2. macOS 同样使用宿主绝对路径，并在 artifact 不可见时多处 `guard ... else { return }`，会形成假绿。
3. Runtime command 可直接导航、打开对象和修改设置，绕过了应被验证的用户交互。
4. 大量测试最终只检查 `visibleScreen/count/ok/event`；即使 UI 字段错误、列表慢或动作未持久化也可能通过。
5. 性能测试由 Runtime 自报区间且与 UI 正确性混合，必须拆分。

完成迁移前，上述测试即使绿色，也只能证明其当前窄 Oracle，不能证明第 25 节对应能力整体通过。

## 本轮新增高价值纵向用例

- `testQualitySessionUsesAppOwnedStoreAndReachesFunctionalEmptyState`
- `testQualityStandardMessagesShowAccurateContentAndSurviveRelaunch`
- `testQualityMessageWorkflowLoadsSecondPageAndPersistsReadActions`
- `testQualityMessageSearchReturnsOnlyTheTargetAndOpensItsRealDetail`
- `testQualityMessageDeleteUndoRestoresTheSameObjectAcrossRelaunch`
- `testSlowMessageLoadBecomesVisibleBeforeDataCompletes`
- `testSlowMessageRefreshKeepsAccurateContentVisibleUntilCompletion`
- `testMessageRefreshPersistsNewProviderResultAndOpensItsRealDetail`
- `testMessageRefreshFailureKeepsSnapshotAndRetryRecoversPersistedResult`
- `testMessageLoadFailureShowsRetryAndRecoversToRealDataState`
- `testQualityPrimaryNavigationUsesRealControlsAndReachesEachProductScreen`
- `testEventClosePersistsAndOngoingFilterReflectsRealProjection`
- `testImportedThingFixtureCanOpenThingDetail`
- `testChannelCreateRenameAndBothUnsubscribeOutcomesPersist`
- `testSettingsPageVisibilityUsesRealControlsAndPersistsAcrossRelaunch`
- `testSettingsServerUsesRealControlsAndScopesDataAfterRelaunch`
- `testGatewayLocalCommitFailureRollsBackBeforeRetryCommits`
- `testSettingsDecryptionRejectsInvalidKeyPersistsAndClearsValidKey`
- `testDecryptionProtectedStoreFailureDoesNotConfigureBeforeRetry`
- `testEncryptedMessageRecoversAfterConfiguringKeyAndSurvivesRelaunch`
- `testCorruptEncryptedMessageFailsSafelyAndSurvivesRelaunch`

前十条进入 PR 核心集，其中 workflow 用 52 条数据跨越真实 page size 50，并验证单条/全部已读、relaunch 与未读筛选。刷新旅程分别证明慢态与上次准确快照共存、Provider 刷新载荷经过规范化摄入后出现在列表和真实详情并在 relaunch 后保留，以及首次失败可见、旧快照保留、同一正式刷新动作重试后恢复；不把直接修改 ViewModel 集合或检查数据库文件当结果。真实导航、Entity、Channel 与 Settings 进入 Nightly/Release。Server 既覆盖候选远端拒绝，也覆盖远端成功后的本地提交中点失败：后者必须回滚、重启仍旧值且重试才提交；rollback 自身失败不得静默。Decryption 必须覆盖存储失败后重启仍未配置、错误 Key 不产生明文、纠正恢复，以及损坏认证密文安全失败。Release 使用显式高价值清单，不让旧 Runtime/state 绿色覆盖新旅程失败。

Quality session 不再只隔离 GRDB：server config、decryption material metadata 与手动编码偏好由 App 自己的 session `config` 目录持有，同 session relaunch 可读、不同 session 不共享，生产 Keychain/gateway token/fallback 不读不写。配置文件损坏或权限错误必须阻断 readiness，不能被默认值伪装成成功。首次完整 Release 的 2/18 失败正是该隔离缺口的负控证据；结构修复后定向 3/3 与完整 18/18 均通过，原失败结果包继续保留。

## 变更影响门禁

`config/quality-impact.json` 把当前产品源码分配到 Messages、Entity、Channel/Settings、Ingress、系统表面、Watch、App shell、共享 UI/媒体和 Release 等具名能力。`scripts/quality_changed.sh` 先执行选择器负控，再运行不低于推荐值的真实 Lane；新产品路径未映射时直接 `BLOCKED`。这只是确定性下限，不能替代对 caller、Store、错误分支和平台消费者的语义追踪。

计划中的 `required_checks` 是必须实际执行并写入收据的补充证据：Appcast/App Store metadata 使用快速语义契约，不启动完整 Release；Fastlane/构建/隐私/回滚变更强制执行发布静态契约并保持 Release Lane。两端各 120 次历史回放已校准旧路径漏选；无效或未知计划直接 `BLOCKED`，不回退为默认绿色。

四个 100k/Watch/concurrency 重型用例已从函数内提前 return 改为框架条件禁用；日常输出必须显示 skipped，并在结果 `not_run` 中列出。`scripts/quality_test.sh performance` 会用 doctor 的 `--host-only` 模式只检查真实所需的 Swift/Package 环境，显式设置 `PUSHGO_RUNTIME_QUALITY=1`，只运行 `RuntimeQualityLargeScaleTests`，保存逐阶段耗时、RSS 与主线程 stall 日志，并把实际执行范围写入独立收据；无关 Simulator 状态不会阻断宿主测试。该 Lane 的阈值是当前宿主机上的 provisional regression ceiling，只防明显倒退；真机启动、帧耗时和 Release ETTrace 仍为 `NOT_RUN`，不得由它代替。
