# PushGo 全栈质量体系实施进度

## 状态

**体系改造进行中，不能宣称完成。** 当前已完成 Runtime/环境底座和 Messages 的首个高价值纵向样板，但设计第 21.2 节的完成条件尚未满足。WP3–WP6 仍有大量当前产品可达能力未迁移，不只是需要真机/外部系统的发布证据。低价值边缘组合不进入日常门禁，但这不能用于延期高频 P0 功能。

## 工作包真实状态（2026-08-28 重新核账）

| 工作包 | 状态 | 已证明 | 尚未完成、不能被现有绿色替代 |
| --- | --- | --- | --- |
| WP0 去伪审计 | `VERIFIED` | 两仓库现有 UI/device 测试均有 disposition，弱 Oracle、路径协议、skip/return 和死代码候选已形成基线 | rewrite/move/delete 的实际迁移属于 WP3–WP7，不因 WP0 退出而视为完成 |
| WP1 Runtime/环境 | `PARTIAL` | 两端 App-owned session Store、确定 fixture、readiness、doctor、teardown、Release 隔离；两端 fixture 用会话级初始化记录与实时业务行数分离，重启不重复播种已被用户合法修改的数据；Apple 隔离历史筛选偏好 | 50 次启动 ≥98% 尚未执行；Apple/macOS 与 Android 遗留 Runtime 仍保留绝对路径/内部 state 协议；准备失败 10 秒内的全套证明不完整 |
| WP2 慢加载样板 | `PARTIAL` | Messages 首次加载 slow/error/retry；主动刷新超过 1 秒出现 slow 且保留上次准确内容；刷新新结果与首次失败后恢复已覆盖 | 里程碑、真实参考设备预算、超预算性能负控未完成 |
| WP3 Messages | `PARTIAL` | 空态、标准字段/详情/relaunch、跨 50 条页界、单条/全部已读、未读筛选往返与重启持久化、搜索代表例、删除 Undo、首次慢/错恢复、慢刷新旧快照、新结果持久化与失败恢复 | channel/tag 筛选、删除不撤销、历史清理、Markdown/media/decrypt 以及 10k UI/性能未完成 |
| WP4 Entity/Channel/Settings/watch UI | `PARTIAL` | Apple/Android Event/Thing App-owned 摄入→投影→准确详情；两端 Event 确认关闭→canonical projection→筛选→relaunch；两端 Thing 三个真实关系页签、准确关联对象打开、逐层返回及 relaunch；两端 Channel 创建→改名→重启→保留/删除历史双退订→再次重启；Sheet 业务错误 owner 已按根/Server/Decryption/Channel entry 分区；两端 server 已覆盖 invalid、候选注册失败不提交、重试成功后才换域/relaunch，候选 device identity 不跨 Gateway 复用；decryption 生命周期与合法 Key 恢复已有 | Event slow/error/duplicate close；Thing 筛选/深链/删除；Channel 订阅既有频道及远端拒绝/补偿；Settings 本地 commit/rollback 写失败、错 Key/坏密文、声音/transport；watch P0 UI 未完成 |
| WP5 Ingress/系统能力 | `PARTIAL` | 两端 ACK/去重/迁移等低层证据较强 | 当前可模拟的通知路由、后台恢复、macOS Window/Status Item、Apple 系统表面仍缺；真实 APNs/FCM/private/权限/安装需外部环境 |
| WP6 性能/a11y/l10n | `NOT STARTED/PARTIAL ASSETS` | Android 部分 semantics、两端慢状态可证伪 | Macrobenchmark/Baseline Profile、Apple XCTMetric、参考设备/SLO 样本、物理辅助任务、多语言/尺寸矩阵未完成 |
| WP7 CI/AI/治理 | `PARTIAL` | lane wrapper、双状态结果、CI、AGENTS/AI policy 已建立；两仓库已实现变更→能力→最低证据合同、未知产品路径阻断、全产品树审计、120+120 次历史产品变更回放校准、补充语义契约与 PR 自动 Lane 选择 | flake owner、两周观察、历史 AI 任务“是否补对测试”的任务级评估和旧 Runtime 退役尚未完成；确定性路径映射只提供下限，不能替代语义影响分析 |

## 已交付

- Apple 设计基线 `2becfd8`、首轮实现 `af69dd1` 与 Android 首轮实现 `7096e43` 已提交；本轮搜索/删除/导航、边测边修和 lane 剪枝保持为独立后续提交，便于审阅与回滚。
- 两仓库均有类型化 Quality Session、唯一 App-owned Store/数据库、内置确定性 fixture、readiness、doctor、teardown 和 Release 隔离。
- 两端均已有 `empty.clean`、`messages.standard`、`messages.workflow`、`messages.large`、`event.standard`、`thing.standard`。Fixture 不再依赖 Runner 读取宿主数据库或把宿主 DB 路径交给 App；52 条 workflow 只跨一个真实页界，不把 1k/100k 性能数据塞入日常功能旅程。
- 消息列表已把首次加载、慢加载、错误、Retry 和真实数据终点建模为产品状态；一次故障保持到用户 Retry，避免自动消耗造成假绿。
- Apple iOS 与 Android 均新增 App-owned 纵向旅程：空态、准确列表字段、详情、重启、慢加载可见、失败可见、Retry 后真实恢复。
- Apple iOS 与 Android 的 52 条消息旅程均从真实列表跨越 page size 50，打开未读详情并观察语义变为已读，执行全部已读、重启核对持久化，再验证仅未读空态和恢复全部消息。Apple 将该旅程纳入 PR 核心集；Android 既有 device 类已覆盖。
- Apple iOS 与 Android 均以类型化 `message_refresh_delay_ms` 在用户主动刷新边界注入一次 2.5 秒延迟；真实 UI 旅程要求 1 秒后 slow 状态可见、准确旧消息全程不消失、完成后 slow 状态退出。Apple 增加正式且可访问的刷新按钮，与下拉刷新共用生产调用链，避免依赖不稳定的模拟手势。
- 两端新增类型化 `message_refresh_scenario`，仅在用户主动刷新边界产生一次 Provider 载荷或首次失败；载荷继续经过正式入站解析、规范化持久化、列表查询和详情，成功用例还验证 relaunch 后保留。失败用例要求旧快照不消失、失败状态可见、同一生产刷新入口可重试并恢复，不允许测试直接修改 UI 集合。
- 该旅程实跑发现并修复 Apple 详情缺少明确可访问关闭动作、同一 quality session 重启重复灌入覆盖业务变更、共享 UserDefaults 跨 session 污染首屏；Android 实跑发现并修复批量已读后从非主线程调用 Toast/announce 的崩溃。
- Apple 事件/事物 fixture 走真实消息摄入与投影，不以“实体文件/行存在”代替详情可打开；用例从真实 Tab 和列表行进入。
- Apple Runner 串行执行、先 build-for-testing、再 test-without-building；只对已知 Runner 启动故障重试一次，业务断言不重试；禁用失败后的长时自动诊断采集。
- Android Runner 在 Application 创建前配置会话，结束时释放 Room、删除唯一 DB 和 session artifacts；日常 device lane 只跑核心旅程与关键数据边界，Nightly/Release 扩展显式代表性集，不再用 Release 跑全部遗留 androidTest。
- 两仓库均实现 `focused/pr/nightly/release` 脚本、CI workflow、`AGENTS.md` 与 AI 增量开发规则。
- 两仓库均新增版本化 `config/quality-impact.json`、可单测的 `scripts/quality_impact.py` 和本地 AI/开发者入口 `scripts/quality_changed.sh`。计划输出真实能力、最低证据、推荐 Lane、升级原因、已知缺口和未映射路径；`READY` 明确不等于产品通过。
- PR/main CI 先审计全部已跟踪产品路径，再对 base/head 变更选 Lane；未知新产品路径直接阻断。文档变更产生结构化 `NOT_RUN`，共享 Store/Room、Runtime、Ingress、系统消费者和构建边界会升级到更高 Lane。
- 影响计划现在还能声明 `required_checks`：机器消费的更新 Feed/Appcast 只进入快速语义契约，不为低成本元数据修改启动完整设备/Release；Fastlane、构建、JNI、隐私和回滚边界则在真实 Lane 前强制执行静态发布契约。声明的计划不存在、不是普通文件、JSON 损坏或含未知检查时直接 `BLOCKED`，不能静默降级。

## 新鲜证据

- 2026-08-28 Settings 错误归属/网关切换切片：根因不是单一漏测，而是 Oracle 缺少“错误 owner 的排他性”和“候选失败前后状态转换”。Apple 将根/Server/Decryption 错误状态真实分区，失败 Sheet 关闭后错误不会回流宿主；iOS/macOS 的候选 Gateway 均须完成 fresh device register + provider route 后才提交。Android 频道表单使用独立错误状态并在 token/远端动作前做本地语义校验，Gateway 同样 prepare→commit，宿主行只读已保存值。两端候选注册不再携带旧 Gateway device key。Apple 网络服务修复了构造器注入被 `URLSession.shared` 绕过的测试接入点，公共 XCUI 文本替换也修复了“真实值等于 placeholder 时错误追加”的基础设施缺陷；Core 新契约 1/1、service 20/20、runtime 10/10、完整 `swift test` 402/402 与 macOS Debug 构建通过，最终 iOS focused 1/1 通过（`build/quality-results/ios/run-1-20260828-104510.xcresult`，单次执行、0 业务重试）。Android 首轮新 Oracle 可信发现宿主行展示 draft，分离 saved/draft 后 server focused 1/1、Channel focused 1/1、完整 unit/Release 构建通过。生产真实公网 Gateway、Apple 真机 APNs、Android 真实 FCM/private 仍不由本切片冒充。

- 本 Settings 产品代码经变更影响选择器升级到 Apple `release` 与 Android `device`：Apple selected/executed 5/5 claim、产品与测试系统双状态 `PASSED`，其中 iOS 高价值清单 17/17 首轮通过、Release Simulator 构建通过，收据为 `build/quality-results/apple-release-summary.json`、UI 结果包为 `build/quality-results/ios/run-1-20260828-080624.xcresult`；随后增强的空白 Save relaunch Oracle 由最终测试字节 focused 1/1 单独证明。Android selected/executed 3/3 claim、17 条 App 旅程与 18 条迁移/删除/ACK 数据边界通过，收据为 `build/quality-results/android-device-summary.json`。两份收据都继续把物理通知/权限/系统表面与物理性能列为 `not_run`，局部通过不代表整产品或 Goal 完成。
- Apple `swift test`：25 个 XCTest 通过；Swift Testing 共发现 398 个测试/36 个 suite，其中 394 个执行通过、4 个 100k/Watch/concurrency opt-in 性能测试被框架明确标为 skipped。后四项进入结果 `not_run`，不再用函数提前返回冒充执行通过。
- Apple iOS PR 核心纵向旅程 6/6 PASSED（空态、准确内容/详情/relaunch、搜索、删除撤销/relaunch、慢加载、失败/Retry）；当前字节结果包 `run-1-20260828-013756.xcresult`。
- Apple iOS `messages.standard`：准确标题/正文、详情、终止重启后仍一致，PASSED。
- Apple iOS 慢加载与失败/Retry：2/2 PASSED；空态纵向用例此前连续两次冷启动 PASSED。
- Apple iOS 搜索准确集合/详情、删除→立即隐藏→撤销→重启持久性均 PASSED；实跑发现并修复了待删除作用域未触发 `List` 重建及父可访问性标识覆盖 Undo 按钮两个产品缺陷。
- Apple iOS 真实点击四个主 Tab 并从频道页进入 Settings 的导航旅程 PASSED；Runtime 直接导航矩阵已退出常规 lane。
- Apple iOS Event 与 Thing 均已从真实 Tab、列表行进入详情并核对准确字段，PASSED。
- Apple iOS Event 关闭 focused 1/1 PASSED（`run-1-20260828-040321.xcresult`，无业务断言重试）；Android 同等 Event 旅程 1/1 PASSED。两端均从真实详情确认关闭，让关闭结果经过生产解析/持久化/投影链，验证 closed 状态、仅进行中筛选排除以及 relaunch 后状态保留；不以内部 count、marker 或测试直接改表作为终点。
- Apple iOS Settings 页面可见性最终 focused 回归 1/1 PASSED（`run-1-20260828-042701.xcresult`，无业务断言重试）；Android 同等旅程 1/1 PASSED。两端均从真实 Channels→Settings 入口关闭 Event 页面、退出并核对入口消失，activity/process relaunch 后仍隐藏；随后用同一控件恢复、打开准确 Event 页面并再次 relaunch 核对。测试没有直接写 preference，也不以控件存在或内部 state 为终点；Apple 两个 Runtime command/state 弱重复已实际删除。
- Settings server/decryption 生命周期字节：Apple server+decryption 组合 2/2 PASSED（`test_sim_2026-08-27T23-02-28-923Z_pid98521_18f05a61.xcresult`），显式 Delete 与无损空白 Save（含空白 Save 后独立 relaunch）最终 1/1 PASSED（`run-1-20260828-082345.xcresult`）；Android 初始生命周期类 3/3 PASSED。两端均从真实 Channels→Settings 控件输入，invalid 留在编辑器并显示 inline feedback；server 成功后核对标准化地址、旧 gateway 频道立即不可见且 relaunch 后准确地址保留；decryption 成功后核对 configured 状态、relaunch 保留、不回显，并通过真实 destructive Delete 核对清除后 relaunch 仍未配置；Apple 额外证明普通空白 Save 不会误删未回显的既有配置。Apple 实跑修复了持久化异常被吞掉仍显示成功、测试 teardown 不终止 App、sheet 尚未离场即做生命周期断言、XCUI 文本替换追加、空白 Save 数据丢失和成功状态未驱动 sheet 离场等缺陷。Android 首次清除 Oracle 可信失败并暴露“用户没有可达删除动作”，两端最终统一为显式删除动作。
- 合法 Key 的真实消息恢复已补齐两端对等证据：合成密文均先经正式 Notification parser 以 `NOT_CONFIGURED/notConfigured` 进入 App-owned canonical Store；用户从真实消息详情打开设置、保存匹配编码的 Key 后，原消息显示准确标题与正文并在 relaunch 后保持。Apple Core 1/1 与 iOS focused 1/1 PASSED，最终结果包 `build/quality-results/ios/run-1-20260828-085454.xcresult`；Android repository/parser/recovery focused 1/1、UI focused 1/1 及整个 `QualitySettingsJourneyInstrumentedTest` 4/4 PASSED。两端 Core 证据同时保留本地身份、已读、接收时间和原密文。Android 首轮 UI 在列表已更新后详情仍显示旧占位文本，可信暴露 15 秒详情缓存一致性 bug；修复为每次打开从 Room 校验后同用例通过。受保护存储/Room 写失败、错 Key/坏密文和生产远端同步失败仍是独立 P0，不能由本合法 Key 证据覆盖。
- Apple 最终 Release 顺序回归首次得到 16/18，两个产品 Oracle 失败而 test-system 保持 `PASSED`：decryption 新 session 已继承前序 Key，server 保存到与前序相同地址后没有触发数据换域。未重跑掩盖；归因到 quality DB 虽隔离但 Keychain/shared fallback 仍跨 session。配置 backend 已迁到 App-owned session 目录，质量模式不读写生产 Keychain/gateway token/fallback；坏 JSON/权限错误不再被 `try?` 吞成默认值。定向 server/decryption/recovery 3/3 后，最终 `build/quality-results/ios/run-1-20260828-093057.xcresult` 为 18/18、0 skipped、无业务重试；`apple-release-summary.json` selected/executed 5/5 且 product/test-system 双 `PASSED`。macOS Debug 共享代码构建也 PASSED。物理 APNs/系统表面和 opt-in 100k 仍在 `not_run`。
- Android 最终 Release 在 API 37 emulator 完成 18 条 App UI/功能旅程与 52 条迁移/删除/ACK/transport 数据测试；100k 用例由框架明确 skipped，Release/R8/Lint 构建 PASSED，`android-release-summary.json` selected/executed 完整且双状态 `PASSED`。首轮审计发现 Gradle 在设备顺序变化后把 51 条数据测试同时扩散到 emulator 与已连接真机；已改为 doctor emulator-first、显式 `ANDROID_SERIAL` override，并把唯一 serial 传给每次 Gradle device invocation。双设备在线的最小负控只在 emulator 运行 1/1，最终 Release 也只出现 `Medium_Phone`，避免日常 Lane 静默扩大成本或状态范围。
- Android 完整 device 首轮在四个消息详情正文断言处因列表行与详情共享同一文本而出现双节点误报；这不是产品内容错误，也没有通过重跑掩盖。Oracle 已限定到真实详情字段 owner 并保留准确正文断言，随后 `QualityMessageJourneyInstrumentedTest` 11/11 与完整 device 17 条 App 旅程 + 18 条数据边界通过；首次失败按 `FAILED_TEST_SYSTEM` 进入归因，后续通过不能抹除它。
- iOS 清除扩展首次在非专用 `Clone 1 of Aegir` 上于 0 个业务动作前停在 `seeding.messages`，记录为测试环境失败（`test_sim_2026-08-27T23-19-11-390Z_pid98521_7d89001c.xcresult`），不计产品失败也不被后续绿色抹除；doctor 明确选择 `PushGo Quality iPhone` 后，同一产品字节与 Oracle 通过。该结果证明 device identity 是运行证据的一部分，不能把任意已启动 Simulator 当成受控环境。
- Apple iOS Channel focused 1/1 PASSED（`run-1-20260828-054300.xcresult`，无业务断言重试）；Android 同等 Channel focused 1/1 PASSED。两端均从真实 Channel UI 创建、改名并重启核对，再分别执行保留历史与删除历史退订，以准确频道行、消息内容和再次重启后的持久状态为 Oracle；只有外部 Gateway accepted mutation 被类型化替身接管，远端拒绝/补偿仍明确未证明。实跑同时修正了两端 readiness 把实时行数误作准备状态、导致合法删除后误失败或重启重新播种的测试系统缺陷；初始化记录只证明准备成功，产品结果仍由 UI/Store 断言负责。
- Apple iOS Thing 关联旅程最终代码的产品断言 focused 1/1 PASSED（`run-1-20260828-044802.xcresult`，Messages/Updates 均验证返回原 Thing/页签；首次启动在任何业务动作前发生控制面丢失并受控恢复，因此测试系统记 `FLAKY`，不是稳定绿色）；Android 同等旅程 focused 1/1 稳定 PASSED。两端均从真实 Thing 打开 Events/Messages/Updates，核对准确关联标题与正文/摘要，打开关联详情并回到原 Thing/原页签，重启后再次打开准确 Event。Apple 负控同时发现并修复“newest-first 批次中的旧尾记录覆盖当前 Thing head”的投影缺陷，并增加旧快照再次到达也不能回退 head 的 Store 回归；完整 `swift test` 通过，邻接 Event close focused 1/1 也在 `run-1-20260828-044513.xcresult` 通过。紧随其后的 Apple 基础设施复核在 0 个业务动作前因 Simulator `No such process` 被分类为 `BLOCKED_TRANSIENT_RUNNER`（`run-1-20260828-044956.xcresult`）；现有默认 runner 已只针对该分类执行一次 shutdown/boot 恢复，本轮不继续重复消耗预算。Android 修复只允许一个顶层 Sheet 消费返回及 AndroidView 详情文本缺少稳定语义的问题。
- Apple iOS 消息 workflow focused 1/1 PASSED（`run-1-20260828-023135.xcresult`，无业务重试）；Android 同等 workflow focused 1/1 PASSED。两端证据均覆盖分页、单条/全部已读、relaunch 和筛选往返，不以 fixture count 或文件 marker 作最终 Oracle。
- Apple iOS 慢刷新 focused 1/1 PASSED（`run-1-20260828-025236.xcresult`，无业务重试）；Android API 37 emulator 同等旅程 1/1 PASSED。刷新新结果与失败恢复的最终回归：Apple 2/2 PASSED（`run-1-20260828-031204.xcresult`，无业务重试），Android 2/2 PASSED。两端均核对准确新标题和详情正文，Apple 成功路径额外核对 relaunch 持久化。
- Apple Release Simulator 构建 PASSED；合法 Quality Session 注入在 Release 中无效，负控 PASSED。
- 本 Settings 切片最终字节的 Apple iOS Release Simulator App、macOS Debug App（`/tmp/pushgo-macos-settings-final2-dd/Build/Products/Debug/PushGo.app`）与 Android Release APK 构建均 PASSED；Apple Release 使用独立 DerivedData 顺序执行，先前并行共用 build DB 的失败按 `INFRA_ERROR` 保留，不替代签名、安装、真机系统验证或 macOS UI 执行。
- 本 Event 切片的 iOS Release Simulator App 重新构建 PASSED。`swift test -c release` 不是当前可用的独立隔离 gate：整套测试会引用仅在 DEBUG 产品代码开放的 storage/push-registration helper，并在到达 `releaseIsolation` 前编译失败；此项按测试系统限制记录，未被 Event UI 或 Release App 构建绿色掩盖，也不为迁移无关测试 helper 追加本轮预算。
- Android JVM：282 tests PASSED；`compileDebugAndroidTestKotlin` 与本 Channel 切片后的 Release APK 新鲜构建均 PASSED。
- Android API 37 emulator：消息/搜索/删除撤销/慢失败恢复/真实导航/Event 准确详情/Thing 三关系页签纵向旅程 9/9 PASSED；隔离的迁移/删除/ACK 核心数据集 18/18 PASSED。
- Apple 与 Android 变更影响选择器单元/负控均为 11/11 PASSED；全已跟踪产品树审计分别命中具名能力且 `unmapped_product_paths=0`。虚构的新 Screen 在两端均为 `BLOCKED`，文档变更均为 `NOT_RUN`，共享 Store/Room 与 Runtime 分别升级到 Nightly/Device 或 Release；Android instrumented-test 变化会升级到 `pr-ui`，不再停在“只编译”。
- 最近 120 个 Apple 与 120 个 Android first-parent 历史提交回放均为 114 `READY` + 6 `NOT_RUN` + 0 `BLOCKED`；有内容的 `NOT_RUN` 各仅一条且均为纯文档，其余为空 diff merge。回放真实发现并修复 Appcast/update feed、旧 Connection Diagnosis、System Integration Settings、Room schema export 与临时发布工作流的漏选。
- Apple Appcast 计划在 `pr` 内真实执行更新分发语义契约后完成 Core/Store/integration 与 iOS 6/6 核心旅程，收据中 selected/executed claim 完整且双状态 `PASSED`；Android update feed 同样在 `pr` 内执行结构语义检查、当前 Feed 的生产 ECDSA 验签及篡改负控，并完成 JVM/编译证据、双状态 `PASSED`。两端 Release 静态契约也各以缩小 focused 产品用例集成验证，selected/executed 无缺口且双状态 `PASSED`。
- Apple PR 核心选择集现为 10 条；既有 6/6 聚合证据之外，分页/已读、慢刷新、新结果与失败恢复均有 focused 证据，尚未用新增后的完整 10 条重新冒充一次聚合执行。Android 当前刷新切片的 JVM 合同、`androidTest` 编译和 emulator 两条旅程 2/2 PASSED。CI YAML、Shell 和 manifest 需在本切片提交前复验。
- 首个 Android emulator 在开测前消失，0 tests，分类为 `BLOCKED_TRANSIENT_RUNNER`；仅一次受控恢复后通过，未把首轮伪装成绿色。
- macOS UI target 已编译；执行被 macOS 系统自动化认证阻断，保持 `BLOCKED`。

## 已完成切片的本轮证据

- 两仓静态检查、单元测试、编译、Release 构建与代表性 UI/数据旅程均已完成；详见“新鲜证据”。
- 红蓝审计、归因分析、双向覆盖反查和残余风险已记录在 `validation.md`；这是同上下文证据，不是独立审查。
- 提交边界：按可独立验证的体系切片分别提交 Apple 与 Android；不 push、不发布。本表不以提交数量作为完成判据。

## 当前执行切片

1. 变更影响下限已实施并完成首轮历史校准：两端路径合同、选择器、补充语义契约、负控、全树审计、120+120 次回放、本地入口与 PR/main CI 门禁均已落地；
2. 下一阶段仍需用历史 AI 任务评估“是否补对 Oracle”，并以连续两周真实变更校准漏选、过度升级、时长和 flake；当前历史样本 0 `BLOCKED` 不能推断未来语义无遗漏；
3. Messages 分页/已读链、慢刷新旧快照、新结果持久化与失败恢复、两端 Event close/filter/relaunch、Thing 三类关联打开/返回/relaunch、Channel create/rename/双退订、Settings 页面可见性、server 数据换域/持久化、decryption key 生命周期和合法 Key 恢复原消息已完成；下一步推进错 Key/坏密文与高价值保存失败边界，然后进入性能/a11y，不扩张 Entity/Channel 边缘组合；
4. 旧 Runtime command/state 测试只在更强旅程接管相同风险后退役；性能、真机与系统证据继续单列 `NOT_RUN/BLOCKED`，不得借模拟器绿色结案。

## 需要 Release/外部环境的明确证据

- 真实 APNs/FCM、通知中心动作、权限、Doze/后台、安装升级、签名、Widget/Spotlight/Intent/Live Activity、Watch 与物理可访问性任务。
- macOS UI 执行在系统认证授权前为 `BLOCKED`。
- Android Macrobenchmark 模块和物理设备性能基线尚未建立；当前慢加载用例证明状态与 Oracle，不声称真实设备性能预算已通过。
- 100k 数据量只在 opt-in 性能 lane 执行，不进入日常回归。

这些项目不得被模拟器绿色覆盖；它们需要真实平台或发布环境，必须在 Release 证据清单中独立报告。但 WP3–WP6 中仍可在本地/模拟器完成的功能缺口不能混入此清单。其余极端设备×语言×状态组合按风险等价采样，不构造全笛卡尔积。若某边缘用例不能对应高影响失败、历史事故或独有技术风险，则不实现或不进入常规 lane。
