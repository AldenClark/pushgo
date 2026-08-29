# PushGo App 全栈自动化质量体系实施设计（重制定稿版）

> 状态：实施规格定稿；第 21–33 节为可执行规范，尚未执行的项目不得宣称已落地
>
> 定稿日期：2026-08-27
>
> 适用范围：`pushgo`（iOS、macOS、watchOS）、`pushgo-android`，以及与真实消息交付验证相关的 Gateway sandbox
>
> 本文取代把“UI 自动化脚本数量、文件存在、版本字段、Automation State 或报告生成”当作产品质量证明的做法。它不宣称当前方案已经落地，也不把文档本身当作测试证据。

## 1. 最终决策

PushGo 不再建设一套孤立的“UI 测试项目”，而是建设一套以真实用户能力为中心的 App 全栈质量系统：

```text
产品能力定义
  -> 可测试的生产代码结构
  -> App 内部受限 Test Runtime
  -> 单元 / 组件 / 集成 / UI / 性能 / 真实系统测试
  -> 按开发场景分级执行
  -> 产品结果与测试基础设施结果分开报告
  -> AI 与开发者遵守同一套增量质量规则
```

系统只有一个最高判据：

> 用户通过真实入口执行真实操作后，在合理时间内得到正确、可见、可持续、可恢复的结果。

文件、版本、构建产物、Fixture、Identifier、数据库行、状态文件、截图文件和报告文件都可以作为准备条件或诊断证据，但不能单独证明产品功能正常。

## 2. 已确认的问题与设计边界

### 2.1 当前事实

1. Apple 已有 `PushGo-iOSUITests`、`PushGo-macOSUITests`、运行时自动化入口、Fixture 和大量 Automation State；Android 已有 Instrumentation、UIAutomator、Compose 测试和运行时质量用例。
2. Apple UI 自动化会把测试 Runner 创建的临时绝对路径传给被测 App。Runner、App 和宿主属于不同沙箱，文件存在不代表另一端有访问权限。
3. Android 自动化仍允许解析任意绝对路径，部分状态写入错误使用 best-effort `runCatching`，可能把权限或 I/O 错误转化为晚到的超时。
4. 既有运行时报告中存在 proxy 指标、Automation State 代替真实 UI、真实 FCM 缺口、固定模拟器、重试后通过、串行报告目录竞争等已知弱点。
5. Apple 和 Android 的发布 CI 主要覆盖构建、包测试、并发和发布完整性，真实 UI 能力与性能尚未成为稳定的日常门禁。
6. Apple 已有自动化存储重定向、启动 Fixture 和 UI 语义标识；Android 已有 `AppContainer`、Instrumentation Context 和测试数据库能力。因此不需要推倒重来，可以沿现有结构渐进替换。

### 2.2 目标

1. 证明功能有没有、交互对不对、页面元素和状态对不对、数据显示对不对、性能是否合格。
2. 默认测试环境可重复、隔离、无需人工复制数据库、处理权限提示或寻找结果文件。
3. 环境故障在正式功能步骤开始前快速识别，不冒充产品失败，也不被重试伪装成通过。
4. 新功能、Bug 修复、性能修改和平台集成在日常开发中自动获得恰当层级的测试。
5. AI 能从仓库内得到明确而精简的当前事实、测试选择规则、命令和停止条件，完成代码、测试、执行、诊断和交付说明的闭环。
6. 测试设施始终从属于产品目的；连续两次修复测试辅助机制仍未推进产品验证时，必须简化、替换或明确阻塞，不能继续无限打磨脚手架。
7. 测试预算优先保护高频核心旅程、历史真实故障、数据丢失/损坏、发布阻断和高影响平台生命周期；极低概率且后果轻微的组合边界，只有成本很低、来自真实事故或承担明确合同/安全责任时才自动化，不为“理论完备”消耗主要实施预算。

### 2.3 非目标

1. 不追求 UI 用例数量、代码覆盖率、Identifier 数量、Mutation Score 或“全绿率”作为最终质量指标。
2. 不要求每个测试维护场景 ID、JSON Manifest、跨仓库 Schema 或繁琐审批记录。
3. 不要求 Apple 与 Android 使用同一测试框架、同一数据库实现或同一 UI 组件。
4. 不把所有测试升级为端到端测试；使用能发现目标缺陷的最低可靠层。
5. 不为测试增加 Release 可激活的任意 SQL、任意路径、任意导航或任意状态修改后门。
6. 不以模拟器结果代替物理设备、真实 APNs/FCM、真实权限、签名、App Group 或发布候选包证据。
7. 不追求所有状态、设备、语言和故障的笛卡尔积；风险相同的长尾组合使用代表例、低层属性测试或人工辅助，不复制成大量低价值 E2E。

## 3. 质量模型：围绕用户能力而不是测试类型

### 3.1 核心能力

| 用户能力 | 必须证明的结果 | 关键失败 |
| --- | --- | --- |
| 启动与进入 | App 可启动，首屏状态正确，可开始操作 | 崩溃、无限加载、错误初始页、权限阻塞 |
| 接收消息 | 通过目标入口到达，规定时间内出现且字段正确 | 丢失、重复、乱序、慢、错误内容 |
| 浏览列表 | 首屏、分页、滚动、已读状态和顺序正确 | 全量阻塞、卡顿、重复页、错序 |
| 搜索与筛选 | 返回且只返回正确集合，清除后恢复 | 漏项、混入、旧结果、慢响应 |
| 阅读详情 | 打开正确对象，内容完整，返回状态合理 | 错详情、截断、旧内容、返回丢状态 |
| 管理消息 | 已读、删除、撤销等真实生效并持久化 | UI 假成功、重启回滚、重复执行 |
| 配置通道 | 设置保存、重启有效，并改变真实传输行为 | 值保存但行为不变、错误无反馈 |
| 失败与恢复 | 空、错、慢、离线、重试、恢复可理解 | 无限 Loading、静默失败、恢复重复/丢失 |
| 生命周期与系统入口 | 前台、后台、冷启动、通知跳转、扩展协同正确 | 错路由、状态丢失、跨进程不一致 |
| 可访问与可理解 | 关键任务可被语义、键盘和辅助技术完成 | 无名称、焦点错误、字体放大不可用 |
| 性能与资源 | 正确结果在预算内出现，滚动/启动/内存可接受 | 数据正确但过慢，或快但内容错误 |
| 升级与数据完整性 | 从受支持旧版本升级后数据仍可使用 | 迁移失败、数据损坏、索引漂移 |

能力表是产品风险地图，不要求每个测试携带永久编号。测试名和代码应直接表达它保护的能力。

### 3.2 一个能力通过的完整链路

```text
真实或明确分层的触发
  -> 经过声明的生产代码边界
  -> 数据被正确转换和持久化
  -> 用户可观察并可操作
  -> 结果在重启 / 失败 / 生命周期变化后保持正确
  -> 全过程满足对应性能预算
```

前置步骤失败只能得到 `BLOCKED`，不能得到功能 `PASSED`。内部状态正确而 UI 错误，仍然是产品失败。

## 4. 产品代码的可测试性架构

### 4.1 统一逻辑分层

两端保留原生技术，但遵守相同职责：

```text
SwiftUI / Compose
  -> ViewModel / Screen State Holder
  -> Use Case / Coordinator
  -> Repository
  -> Database / Network / Push / Permission / OS Adapter
```

规则：

1. UI 不直接读数据库或网络。
2. ViewModel 暴露明确、有限、穷举的页面状态和用户 Action。
3. 业务规则不依赖具体 UI、真实时间、随机数、线程、系统权限或网络实现。
4. Repository 拥有持久化语义，数据库实现拥有事务和迁移。
5. 平台权限、通知、Keychain/Keystore、App Group、后台调度和 Push Token 位于适配层。
6. 测试替换发生在 Composition Root，不在页面中散布 `if uiTest`。

### 4.2 Composition Root

Android 以 `AppContainer` 为 Composition Root，逐步从“内部固定创建所有具体依赖”改为接收运行配置和少量稳定变化轴：

```kotlin
sealed interface AppRuntimeProfile {
    data object Production : AppRuntimeProfile
    data class UiTest(val session: TestSessionConfig) : AppRuntimeProfile
    data class IntegrationTest(val session: TestSessionConfig) : AppRuntimeProfile
}
```

Apple 以 `AppEnvironment` 为 Composition Root。避免为巨大的 `LocalDataStore` 创建一个数百方法的总协议，只按真实消费者拆出窄能力，例如：

```text
MessageQuerying
MessageMutating
SettingsReading / SettingsWriting
NotificationIngressHandling
PermissionChecking
```

仅在存在真实替代实现、所有权边界或测试价值时增加抽象；不为“看起来架构完整”给每个类型制造协议。

### 4.3 显式 UI 状态

异步页面至少区分适用的状态：

```text
initial
loading
content
empty
failed
recovering
refreshingExistingContent
```

不能用一个 `isLoading` 同时表达首次加载、刷新、失败和空数据。状态必须带有用户需要的信息：是否可重试、是否保留旧内容、错误呈现方式、恢复完成后的结果。

这些状态首先服务真实 UX，其次才被测试观察。Automation Runtime 不得单独声明“页面已成功”。

### 4.4 可控的不确定边界

以下边界应在 Composition Root 可替换：

- Clock；
- ID/随机数生成器；
- 网络客户端和连接状态；
- 数据库位置/Store Factory；
- Permission Client；
- Push Token Provider；
- Keychain/Keystore Adapter；
- Notification Presenter；
- Background Scheduler；
- Coroutine Dispatcher / Task Scheduler；
- Retry/Backoff Policy。

测试实现必须确定、可复位、有界。不能为了让测试稳定而关闭产品正常使用的并发、刷新、校验或持久化规则。

### 4.5 UI 语义契约

关键页面、内容、操作和状态应有稳定语义：

```text
screen.messages.list
state.messages.loading
state.messages.empty
state.messages.failed
action.messages.retry
message.row.<stable-message-id>
action.message.delete
filter.unread
```

语义包括角色、名称、当前值、Enabled/Selected 状态和必要错误提示。禁止用列表下标作为业务身份。Identifier 是定位手段，不是覆盖率。

Apple/Android 已有相当数量的 Accessibility Identifier/Test Tag，应保留有用户意义的部分，删除或避免扩展纯内部状态标记。

## 5. 数据链路与验证点

### 5.1 主消息链路

```text
Gateway / APNs / FCM / Test Ingress
  -> Payload Parser
  -> Decrypt / Normalize
  -> Provider / Inbound Ingress Coordinator
  -> Operation / Delivery Ledger
  -> Message / Entity Repository
  -> GRDB / Room source tables
  -> summary / stats / search / facet derived state
  -> ViewModel
  -> list / detail / search UI
  -> notification / widget / watch / system surfaces
```

每个关键场景至少需要一个首尾对账：输入中的稳定业务字段与用户最终看到的字段一致。派生索引、Automation State 和数据库快照只能帮助定位中间哪一段失真。

### 5.2 数据不变量

1. 同一作用域内同一消息身份不得重复展示。
2. 数据源提交成功后，列表、详情、搜索、统计和系统表面最终一致。
3. 派生索引失败不能删除或篡改源消息。
4. 已读、删除等操作在声明的持久化和跨表面范围内一致。
5. 重试、重复投递和进程重启不能放大副作用。
6. 升级失败必须保持旧数据可恢复；迁移事务失败不允许留下半迁移状态。
7. 测试日志不得记录 Token、密钥、完整敏感 Payload 或真实用户数据。

### 5.3 适合属性/变形测试的关系

- 同一消息重复投递两次，用户仍只看到一条；
- 增加无关消息不改变目标搜索结果的正确性；
- 重启前后同一查询的业务结果等价；
- 分页拼接结果与同一数据集的有界全量参考结果等价；
- 消息排序不受插入批次划分影响；
- 先失败后重试与一次成功的最终业务状态等价；
- 派生索引重建前后，源消息详情结果不变。

## 6. Test Runtime 最终设计

### 6.1 职责

Test Runtime 只负责：

1. 接收受限的 `TestSessionConfig`；
2. 在 App 自己的 Container 中创建唯一测试会话；
3. 组装测试依赖；
4. 通过声明入口准备场景；
5. 提供 readiness 和有限诊断；
6. 在结束时释放资源。

它不负责直接设置 UI 成功状态，也不提供任意代码、任意 SQL、任意文件路径或任意导航执行。

测试接缝权限如下：

| 接缝 | 构建范围 | 允许用途 | 能否作为产品通过判据 |
| --- | --- | --- | --- |
| Dependency Injection / Store Factory | 全部构建 | 生产组装与测试替代 | 间接；最终仍看行为 |
| Accessibility Semantics | 全部构建 | 用户可访问性和 UI 定位 | 可以观察真实内容/状态 |
| 业务里程碑 Trace | 全部构建的低成本版本 | 性能归因和故障定位 | 不能单独证明 UI 正确 |
| Scenario Seeder | Debug/UITest | 准备声明数据集 | 不能证明被绕过的上游链路 |
| TestIngress | Debug/UITest | 调用真实 Ingress Coordinator | 可证明其接入点之后的链路 |
| Fault Profile | Debug/UITest | 在依赖边界制造错、慢、乱序 | 与真实结果断言组合后可以 |
| Startup Route | Debug/UITest，有限白名单 | 快速进入视觉/组件目标页 | 不能证明导航旅程 |
| Readiness/内部诊断 | Debug/UITest | 判断是否可开始、定位首错 | 永远不能代替产品结果 |
| 任意 SQL/绝对路径/任意状态修改 | 禁止 | 无 | 无 |

### 6.2 会话配置

最小配置：

```text
runID
scenario
cleanStart
fixturePayload 或 deterministic seed/scale
faultProfile
permissionProfile
```

不把它扩展为全仓库场景注册中心。日常场景优先使用测试代码中的类型和工厂；只有 Runner 必须跨进程传递的字段进入配置。

### 6.3 App 自有存储

```text
<App Container>/Library/Application Support/UITests/<runID>/
```

或 Android 对应 `filesDir/databases` 下的会话目录。

规则：

- UI Runner、ADB shell 和宿主脚本不知道真实数据库路径；
- 小 Fixture 以 Bundle、Base64 或 Instrumentation Argument 传递内容；
- 大型性能数据由 App 内确定性生成器按 seed/scale 批量生成；
- 普通 UI 测试禁止复制 DB/WAL/SHM；
- 迁移专项测试可使用测试拥有的版本化数据库 Fixture；
- 真实用户数据和生产数据库永远不作为自动化输入。

### 6.4 Readiness 状态

```text
requested
  -> environment_preparing
  -> app_launched
  -> storage_ready
  -> fixture_ready
  -> ui_ready
  -> executing
  -> teardown
  -> PASSED / FAILED / FLAKY / BLOCKED
```

禁止边：

- 未 `storage_ready` 就开始功能断言；
- Fixture 导入失败后继续运行并把空页面当产品结果；
- 功能断言失败后通过原地重试改成 `PASSED`；
- teardown 失败但仍宣称环境已完整释放。

Readiness 应实际执行一次 App 内 Store 打开和最小事务探针，而不是检查数据库文件存在。它是环境前置条件，不计入产品功能得分。

冷启动性能测试是例外：Store 打开和首屏就绪属于被测行为，计时从进程启动开始。

### 6.5 故障注入

允许在真实边界注入：

```text
network.delay / timeout / malformedResponse
database.readDelay / busy / failNextRead
ingress.dropAfterParse / duplicate / outOfOrder
clock.advance
permission.denied / restricted
background.interrupt / processRestart
```

每个注入必须：仅测试构建可用、默认关闭、作用域为 runID、次数有界、有 reset/teardown、保留真实业务路径。

禁止在 UI 中写 `if uiTest { showLoadingForThreeSeconds() }` 来冒充慢依赖。

### 6.6 Release 隔离

必须有构建级控制证明：

- Release 不包含或不能激活 Test Runtime 控制面；
- Release 不接受测试启动参数启用任意场景；
- 测试 Receiver/URL Scheme/Provider 不对 Release 导出；
- 测试 Token/Fixture 不进入 Release 资源；
- 发布验证可以使用正式候选包，但只能通过真实外部入口驱动。

这属于安全与发布完整性检查，不计入产品功能覆盖。

## 7. 分层测试套件

### 7.1 单元与属性测试

保护：解析、验证、排序、过滤、去重、状态转换、错误映射、重试策略、时间规则、幂等和数据不变量。

要求：快速、无设备、无真实网络、结果确定。业务规则变化优先在这一层获得第一条失败敏感测试。

### 7.2 组件与状态测试

保护：ViewModel/State Holder 与单个 SwiftUI/Compose 组件的行为和主要视觉状态。

覆盖适用的 Loading、Content、Empty、Failed、Recovering、长文本、动态字体、深色模式和本地化。Snapshot 只用于真实视觉风险，不阻止无意义的像素差异。

### 7.3 数据与平台集成测试

保护：真实 GRDB/Room、迁移、事务、索引、Repository、Keychain/Keystore Adapter、权限 Adapter、通知路由和生命周期边界。

使用测试拥有的 Store/Container。数据库专项测试可以观察数据库，但不能把这种观察冒充 UI 能力。

### 7.4 Feature Integration

保护一项能力从 Use Case/Coordinator 到 UI State 的完整路径。例如：

```text
TestIngress
  -> ProviderIngressCoordinator
  -> Repository
  -> Store
  -> MessageListViewModel
  -> Content state
```

这一层比完整设备 UI 快，负责大量成功、失败、乱序、取消和恢复组合。

### 7.5 App UI 核心旅程

数量保持少而关键，首批至少覆盖：

1. 启动并看到正确初始状态；
2. 接收一条消息、看到正确列表行、打开正确详情；
3. 搜索目标消息并排除非目标；
4. 已读/删除后重启仍正确；
5. 慢加载有反馈、超预算失败、恢复后内容正确；
6. 设置通道后重启有效，并在相应集成层证明行为改变；
7. 系统通知打开正确目标。

UI 最终断言必须来自用户可观察内容和交互。内部状态只用于诊断或选择性双重对账。

### 7.6 性能测试

每项性能测试必须同时具备：

- 代表性工作负载和数据分布；
- 指定设备/构建/冷暖状态；
- 正确性保护；
- 明确测量区间；
- 样本和方差；
- 初始预算和基线；
- 超预算时失败，而非只打印数字。

Apple 使用 XCTest Metrics、XCTClock/Memory/Hitch/Signpost 等原生能力；Android 建立独立 Macrobenchmark 模块测启动、滚动、FrameTiming 和关键 TraceSection。模拟器可用于趋势和故障发现，但物理设备才承担发布性能结论。

关键业务里程碑：

```text
ingress.accepted
payload.parsed
message.persisted
query.started
query.completed
ui.content_ready
ui.first_content_drawn
```

日志使用 correlation ID，不记录敏感正文或凭据。

性能预算的制定顺序：先定义用户可接受的结果时间和参考设备档位，再用当前候选构建测量方差并设置可执行阈值；不能直接把一个已经很慢的历史平均值加宽后称为 SLO。前两周允许以非阻塞趋势收集校准噪声，校准完成后必须进入硬判定。每次预算调整需要用户影响、设备/工作负载变化或可靠测量证据，不能只因为测试变红。

### 7.7 真实系统测试

发布前在受控 sandbox/物理设备验证：

- 真实 APNs/FCM/Gateway；
- 通知权限和系统提示；
- 冷启动、后台、终止状态；
- App Group、Widget、Watch；
- 正式签名候选包；
- 从受支持旧版本升级；
- 代表设备性能。

凭据或设备不可用时状态为 `BLOCKED` 或 `NOT RUN`，不得用 synthetic token 证明真实推送。

## 8. 平台落地设计

### 8.1 Apple

1. iOS 与 macOS 的自动化存储统一使用 App 内 `sandbox-tmp:<runID>` 或等价 token，不再传宿主绝对存储路径。
2. 停止依赖 `automation-response.json`、`automation-state.json`、`events.jsonl` 作为功能判据。启动命令用 Launch Environment；结果用真实 UI、Accessibility、XCTest Activity/Attachment 和统一日志。
3. `PushGoAutomationRuntime.shared.record...` 从页面逐步迁移到 ViewModel/业务里程碑 Observer；页面只渲染状态和提供语义。
4. `AppEnvironment` 负责 Production/UITest/IntegrationTest 依赖组装。
5. GRDB 测试使用 App 自有会话 Store；App Group 共享另设平台集成套件。
6. UI Test Runner 动态选择兼容 Simulator，不在脚本中固化不存在的设备名/OS；构建与运行分离，复用 `build-for-testing`。
7. 非权限场景受控预置权限；权限专项场景使用干净 Simulator/Device 和真实系统提示。
8. XCTest 结果以 `.xcresult` 为标准产物，失败时才附加截图和有限日志。

### 8.2 Android

1. `AppContainer` 接收 Runtime Profile、Store Factory 和必要适配器。
2. 自动化接口拒绝任意绝对路径，只接受 App 内相对 token 或内容输入；测试控制面写入失败必须显式阻断，不能静默吞掉。
3. Instrumentation 使用 `targetContext`/App Context 和 App 内 Test Runtime；外部 ADB/UIAutomator 不读取 `/data/data` 数据库。
4. Gradle Managed Devices 管理参考 Emulator 生命周期；Android Test Orchestrator 隔离适用测试。是否逐用例 `clearPackageData` 按状态语义选择，不对持久化/升级测试清除目标数据。
5. Compose 测试使用 Semantics、条件等待和必要 Idling Resource；禁止固定 sleep 充当同步。
6. 建立独立 Macrobenchmark 模块；性能 Loop 从外部以用户方式操作 App，并包含正确内容检查或紧邻正确性保护。
7. FCM、Google Account、系统通知等真实能力进入明确的真实系统 Lane；缺失账号不再降级成 synthetic 后宣称真实能力通过。
8. 并行 Shard 必须使用独立 Managed Device 和输出目录；未证明隔离的物理设备和固定端口串行运行。

## 9. 测试环境与结果判定

### 9.1 一次运行

```text
Preflight
  -> 分配独立设备/会话/存储/端口
  -> 安装并启动候选构建
  -> App readiness
  -> 执行真实用户步骤
  -> 用户结果断言
  -> 必要的性能/数据对账
  -> 失败时收集最小诊断
  -> teardown 并确认释放
```

Preflight 只做能阻止运行的真实检查：设备可用、安装、启动、Store 可写、依赖服务 Ready。禁止扩展成大量文件/版本形式检查。

### 9.2 状态

| 状态 | 含义 |
| --- | --- |
| `PASSED` | 最新执行证据满足用户结果判据 |
| `FAILED` | 用例已执行，产品或测试判据不满足 |
| `FLAKY` | 相同输入和环境尝试结果不一致 |
| `BLOCKED` | 设备、权限、凭据、Runner、Store 或服务阻止执行 |
| `NOT RUN` | 未执行，保留原因和影响范围 |
| `WAIVED` | 有明确责任人和理由的授权遗漏；永远不等于通过 |

报告分为两栏：

1. **产品能力结果**：接收、搜索、详情、管理、恢复、性能等；
2. **测试/发布设施结果**：构建、设备、签名、版本、报告、凭据、环境。

设施全绿不能让产品能力变绿。

状态之外再记录一个原因分类，避免所有红色都落到产品团队：

| 原因分类 | 判定方式 | 处理 |
| --- | --- | --- |
| `product` | App 已 Ready，真实用户结果、数据或性能不满足 | `FAILED`，进入产品诊断 |
| `test` | 测试代码、Fixture 或 Oracle 自身无法形成有效判定 | `BLOCKED` 或 `FLAKY`，修测试但不宣称产品失败 |
| `environment` | 设备、权限、账号、签名、OS 或外部 sandbox 不可用 | `BLOCKED`/`NOT RUN`，保留受影响能力 |
| `infrastructure` | Runner、ADB/XCTest、端口、报告或设备管理异常 | `BLOCKED`/`FLAKY`，执行一次有条件恢复 |

归因以最早偏离预期的可观察检查点和区分实验为依据，不根据日志中最后一行或重跑结果猜测。

### 9.3 重试

只允许对已分类的瞬态基础设施故障自动恢复一次，例如设备掉线、Simulator 启动失败或 XCTest Runner 握手失败。必须保留第一次失败。

功能断言失败、数据错误、页面超时、错误按钮和性能超预算不自动重试。第一次失败、第二次通过仍为 `FLAKY`，不是稳定 `PASSED`。

## 10. 按场景分级执行

### 10.1 Focused / 本地修改

目标：开发者或 AI 在几分钟内获得最敏感反馈。

- 改动模块的单元/状态测试；
- 必要的数据/组件测试；
- 受影响能力的一条窄 Smoke；
- 不启动无关平台和全量设备矩阵。

路径映射只能定义确定性的最低命令，例如改 ViewModel 至少运行对应状态测试；它不能独自决定完整测试范围。动态注册、共享协议、数据库 Schema、跨进程状态、配置和公共消费者必须由变更影响图补充，否则“文件没匹配到规则”会再次成为漏测理由。

### 10.2 Pull Request

- 两端主机单元和集成测试；
- 受影响能力在一个参考 Simulator/Managed Device 的 UI Smoke；
- 数据迁移、并发、协议或安全变化的专项门禁；
- Test Runtime Release 隔离检查；
- 产品与基础设施结果分开输出。

### 10.3 Main / Nightly

- 全量 Hermetic 能力回归；
- 空、错、慢、离线、重复、乱序、恢复；
- 视觉、动态字体、本地化和自动无障碍检查；
- 10k/100k 数据层和 UI 性能趋势；
- 多参考 OS/设备矩阵；
- 有凭据时的 Gateway sandbox，不把缺失真实 FCM 路径降级成通过。

### 10.4 Release Candidate

- 正式候选包安装；
- 从受支持旧版本升级；
- 物理 Android/iPhone 和适用 Mac/Watch；
- 真实 APNs/FCM/Gateway；
- 系统通知、权限、后台和冷启动；
- 代表设备性能；
- 核心能力闭环。

执行时间预算先作为运营目标，不立即作为产品门禁：Focused 目标 3 分钟内、PR 目标 15 分钟内、Nightly 目标 90 分钟内、Release 目标 120 分钟内。垂直样板实测后重新校准；超时优先优化、缓存、分片或缩小无关范围，不能删掉关键能力判据。

## 11. 日常开发与测试增量规则

### 11.1 代码变化到测试义务

| 变化 | 最低测试义务 |
| --- | --- |
| 新业务规则 | 普通、边界、失败单元测试 |
| 状态转换变化 | ViewModel/状态转换测试，含禁止转换 |
| 解析/解密/规范化 | 表驱动、异常输入、属性测试 |
| Repository 查询 | 真实 Store 集成测试，结果集合/顺序断言 |
| 数据库 Schema | 从所有受支持旧版本前向迁移与失败回滚测试 |
| 新页面 | Loading/Content/Empty/Error 和主要交互组件测试 |
| 新用户操作 | 成功、失败、重复操作、持久化结果 |
| 关键用户旅程变化 | 更新至少一条真实 UI 旅程 |
| 网络/重试/队列 | 超时、取消、幂等、乱序、恢复 |
| 权限/通知/App Group | 平台集成；必要时发布前物理设备 |
| 性能敏感路径 | 带正确性保护的基准和初始预算 |
| 线上 Bug | 修复前复现或等价负向控制；最低层回归，必要时补 UI 逃逸层 |
| 纯内部重构 | 通常不新增用例，运行受影响测试并保护既有行为 |
| 纯视觉变化 | 只更新有意义的视觉状态，并人工审查差异 |

### 11.2 每个测试的五问

1. 它证明哪个用户或业务能力？
2. 哪个真实回归会让它失败？
3. 输入是否经过声明的生产路径，还是绕过了目标代码？
4. 最终判据是否来自用户可观察结果或明确业务契约？
5. 产品已经坏了，它是否仍可能通过？

第五问为“是”时，必须重构、降级为诊断检查或删除。

### 11.3 Bug 修复

1. 保存第一次失败；
2. 最小化输入和序列；
3. 在证据允许时列出至少两个原因假设；
4. 用最便宜的区分实验确认归因；
5. 修根因并让回归测试在旧行为/扰动下失败；
6. 运行受影响模块和代表性能力路径；
7. 若三个假设/修复均未推进，重新打开复现、环境、设计或 Oracle，不继续盲改。

日志证明发生顺序，不自动证明因果。Five Whys 可用于提问，不单独作为根因证据。

### 11.4 轻量 PR 说明

只保留四项：

```text
用户行为变化：
主要失败/恢复状态：
新增或更新的测试：
未运行的真实环境验证：
```

不要求测试数量、覆盖率截图、场景 Manifest、审批哈希或方法论报告。

## 12. AI 日常开发闭环

### 12.1 仓库可读性建设

实施阶段在 `pushgo` 和 `pushgo-android` 各自 Git 根增加精简 `AGENTS.md`，内容只包含：

- 产品质量最高原则；
- 指向本设计或拆分后的仓库本地质量文档；
- 代码变化到测试义务；
- 原生命令入口；
- 禁止弱化测试和测试后门；
- 结果状态和未运行证据规则。

详细方案不复制进 `AGENTS.md`，防止上下文过载和文档漂移。精确命令由可执行脚本拥有，文档链接到脚本。

日常 AI 任务默认读取 `AGENTS.md`、受影响代码和对应脚本帮助，不要求把本文 20 个章节全部装入上下文。只有涉及测试架构、测试接缝、能力分级、性能预算、真实系统、AI 规则或方案迁移时，才按标题检索本文相关部分。代码和可执行脚本优先于可能陈旧的 prose；发现不一致时先报告并修正当前真相。

目标入口：

```text
scripts/quality/focused
scripts/quality/pr
scripts/quality/nightly
scripts/quality/release
```

Apple/Android 保留各自实现。根级说明只描述语义，不建立一个脆弱的跨仓库超级 Runner。

### 12.2 AI 必须执行的步骤

1. 读取有效 `AGENTS.md`、当前设计和受影响源代码；
2. 用一句话写出用户可观察结果和保护行为；
3. 建立当前变更影响图：调用者、数据、错误、配置、生成物、平台和测试；
4. 选择能发现目标缺陷的最低测试层；
5. 代码与测试同一切片实现；
6. 先跑最窄测试，再跑受影响模块和一条代表性集成/能力路径；
7. 对关键或容易造假的 Oracle 使用修复前失败、负向 Fixture、局部扰动/Mutation 或交叉 Oracle；
8. 检查最终 Diff 中是否有测试放宽、跳过、Fixture 随意更新、静默错误或 Release 测试后门；
9. 报告 `PASSED/FAILED/FLAKY/BLOCKED/NOT RUN/WAIVED`，并说明环境和证据限制；
10. 不自行 commit、push、发布或使用生产凭据。

### 12.3 确定性控制与 AI 判断的分工

确定性脚本负责：

- 基础编译/单元命令；
- 设备和资源分配；
- 超时、结果收集和清理；
- 必跑门禁；
- Release Test Runtime 隔离；
- 输出状态格式。

AI 负责：

- 理解用户目的；
- 识别变更影响和历史风险；
- 选择/补充风险相关测试；
- 设计失败敏感 Oracle；
- 诊断第一次失败；
- 说明未覆盖边界。

AI 不得自行决定：

- 删除或放宽既有关键断言；
- 把 `BLOCKED/NOT RUN` 改成通过；
- 因为时间长而跳过必要迁移/安全/真实系统门禁；
- 更新 Snapshot 基准而不审查用户可见差异；
- 用内部状态替换用户结果；
- 使用真实生产数据或凭据。

### 12.4 防止 AI 过拟合可见测试

关键改动采用小型反例闭环：

```text
冻结用户结果和既有保护行为
  -> AI 提出实现和测试
  -> 使用不同推导方式寻找反例
  -> 反例成立则成为永久回归
  -> 再跑原始与受影响证据
```

可用反例来源：属性生成、局部 Mutation、改变顺序/重复/取消、公共消费者检查、旧版本 Fixture、故障注入。禁止通过删除、跳过或改弱测试让实现存活。

### 12.5 AI 工作流本身的验证

选择一组真实历史任务类型做周期性抽样，而不是构造只会通过的 Demo：

- 小型业务 Bug；
- UI 状态新增；
- 数据库迁移；
- 慢加载/性能回归；
- 权限或系统入口；
- 跨 Apple/Android 语义一致性。

保留第一次尝试，分别观察：最终功能、测试选择、是否弱化 Oracle、是否正确区分环境失败、运行成本和残留副作用。归因时一次只改变 Prompt/指令、仓库上下文、工具入口、环境或模型中的一个因素。样本不足时只做探索性结论，不输出伪精确的 AI 质量分数。

## 13. 方法验证与方案修正记录

方法数量不是质量证明。以下方法只在能改变设计、Oracle 或实施顺序时采用。

| 方法 | 对候选方案的攻击/检查 | 发现 | 已纳入的修正 |
| --- | --- | --- | --- |
| 结果映射 / Specification by Example | 用“接收一条消息、慢加载、重启后已读”等例子追问通过含义 | 文件、状态、数据库行可能全部正确但用户结果错误 | 所有核心能力使用首尾用户结果；内部证据降为诊断 |
| 假设映射与 Pre-mortem | 假设改造半年后仍然无效，寻找最可能原因 | Test Runtime 可能变第二套产品逻辑；CI 可能只维护脚手架 | Test Runtime 只组装/注入边界；辅助机制两轮不推进即简化 |
| 变更影响图 | 追踪 Composition Root、Store、Ingress、ViewModel、UI、Runner、CI 和文档 | 大爆炸改造会同时破坏现有测试和用户路径 | 采用纵向样板后迁移；旧套件按能力逐条替换，不先删除 |
| 数据链路/来源追踪 | 从 Push/Test Input 追到 Store、派生索引、UI、Watch/Widget | 直接 Seed 可绕过 Ingress；派生表可与源消息漂移 | 测试声明注入深度；增加源/派生/用户表面对账和敏感数据限制 |
| 有限状态转换表 | 检查环境准备、App Ready、执行、失败、重试、清理 | 现有超时难区分环境与产品；重试可能洗绿 | Readiness、类型化状态、禁止边、一次基础设施恢复 |
| FMEA | 枚举跨沙箱、旧数据、权限提示、共享设备、Fixture、日志、清理失败 | 高风险集中在跨所有权访问和共享状态，不是断言语法 | App 自有 Store、唯一 runID、资源租约、失败显式化、最小证据 |
| Fault Tree | 顶层事件设为“套件绿但产品坏”和“套件无法启动” | 错 Oracle、绕过生产路径、静默错误、缺失真实系统、固定环境均可达顶层事件 | 用户结果 Oracle、负向控制、真实系统 Lane、动态设备、禁止静默错误 |
| 红方对抗 | 站在“让 CI 尽快变绿”的实现者角度尝试钻空子 | 可用 skip、宽阈值、内部状态、自动重试、随意更新截图绕过 | 跳过状态分离、性能硬判据、Snapshot 人审、功能失败不重试 |
| 蓝方审查 | 检查需求一致性、平台原生性、维护成本和迁移路径 | 全平台统一 Runner/Schema 会增加耦合并降低原生证据 | 只统一能力语义和报告状态；Runner/工具保持平台原生 |
| 归因分析 / 区分实验 | 对“按钮没出现”拆成产品、测试、环境、设施假设 | 单看最终超时无法定位；日志顺序不是因果 | 保存首错、最小复现、一次改变一个因素、里程碑 Trace |
| Oracle Challenge / Mutation | 故意丢消息、错搜索、延迟、取消持久化、错通知路由 | 许多形式断言不会失败 | 关键 Oracle 必须有修复前失败、扰动、Mutation 或交叉 Oracle |
| 质量属性权衡 / ATAM 视角 | 比较真实性、稳定性、速度、生产纯度、跨平台一致性 | 单一“最真实”环境会不稳定；单一 Hermetic 又遗漏系统风险 | Hermetic 默认 + 平台集成 + 真实交付三层；生产/测试 Composition 隔离 |
| 复杂度审计 | 删除不能直接提升缺陷发现或可执行性的治理元素 | 强制 Manifest、覆盖率目标、每测双 Oracle、全矩阵会形式化 | 不引入这些要求；只在复杂环境/高风险变化使用矩阵 |
| AI 轨迹评估 | 不只看最终 Patch，也看跳过、重试、环境分类和副作用 | AI 可得到正确代码却通过错误轨迹削弱测试 | 确定性安全边界、第一次尝试保留、反例闭环、动作权限分离 |

### 13.1 同一上下文红蓝审查限制

本文的红方和蓝方由同一设计上下文执行，能发现内部矛盾，但不是独立评审，仍存在共同规格和思维盲区。实施完成后，涉及 Test Runtime Release 隔离、持久化迁移、真实推送和最终 Oracle 的关键 Diff 应进行独立上下文评审；本设计阶段不把该门禁冒充已完成。

## 14. 轻量保证论证

**主张：** 实施后的体系能对 PushGo 核心用户能力提供有意义、可重复且不被形式检查冒充的发布信心。

支持链：

1. 能力覆盖来自用户旅程和失败/恢复状态，而不是测试文件清单；
2. Hermetic 环境通过 App 自有存储、唯一会话和原生设备管理降低非产品失败；
3. Oracle 通过用户结果和负向控制证明失败敏感性；
4. 性能通过真实用户区间、正确性保护和原生指标判定；
5. 平台/真实交付能力由物理设备和真实系统 Lane 单独证明；
6. AI 由确定性脚本、仓库当前事实、测试义务和反例闭环约束；
7. `BLOCKED/NOT RUN/FLAKY` 不会被合并为通过。

主要反证条件：

- 关键测试仍可绕过目标生产路径；
- Test Runtime 进入 Release 或修改产品结果；
- CI 长期不执行 UI/性能/真实系统 Lane；
- Snapshot/基线在无审查时自动接受；
- AI 可自行跳过、降级或洗绿；
- 物理设备/真实推送缺口被 synthetic 结果替代。

任何反证条件成立时，主张降级，只能报告已实际证明的更窄范围。

## 15. 实施工作包与依赖顺序（早期框架，已由第 29 节实施规格取代）

一次性完成最终目标，但以可回滚的纵向切片实施，不使用大爆炸提交。

### WP0：基线和去伪分类

工作：

- 盘点现有 Apple/Android 测试，按“保留、重写、删除、基础设施检查”分类；
- 标出直接 DB/文件/Automation State、proxy 性能、skip 和重试；
- 冻结首批七条核心 UI 旅程；
- 保存现有首错和运行时间基线。

退出：每条现有关键测试都明确证明什么、不能证明什么；未删除任何仍独占能力覆盖的旧测试。

初步工作量：3–5 人日。

### WP1：Test Runtime 与环境基础

工作：

- Apple `AppEnvironment`、Android `AppContainer` 引入 Runtime Profile；
- App 自有会话存储、唯一 runID、readiness、teardown；
- 删除/拒绝跨沙箱绝对路径；
- 状态结果分类和一次基础设施恢复；
- Release 隔离检查；
- Managed Device/动态 Simulator 选择。

退出：连续运行参考启动 Smoke，不需要手工权限、路径或数据库操作；环境失败在功能步骤前被类型化识别。

初步工作量：8–12 人日。

### WP2：消息接收—慢加载纵向样板

工作：

- 明确 Message List UI State；
- TestIngress 进入真实 Ingress Coordinator；
- 一条消息接收、展示、详情、字段对账；
- 延迟、超时、失败、重试和恢复；
- 业务里程碑与首个性能预算；
- 负向控制：丢持久化、错字段、超延迟时测试必须失败。

退出：Android/iOS 均能发现“数据加载过慢但最终有数据”的回归，并区分环境阻塞与产品失败。

初步工作量：10–15 人日。

### WP3：核心能力迁移

工作：搜索/筛选、详情、已读/删除/撤销、设置/通道、通知跳转、生命周期、升级数据。

退出：首批核心旅程全部使用新架构；对应旧的内部状态型断言已删除或降级为诊断。

初步工作量：15–25 人日。

### WP4：性能、视觉、无障碍和真实系统

工作：Apple Metrics、Android Macrobenchmark、动态字体/本地化/深色、自动和人工无障碍、真实 APNs/FCM/Gateway、物理设备和候选包升级。

退出：性能测试有正确性保护和阈值；真实系统缺口不再由 synthetic/proxy 代替。

初步工作量：10–15 人日。

### WP5：CI 与 AI 研发闭环

工作：

- 两仓 `AGENTS.md` 质量规则；
- `scripts/quality/*` 原生入口；
- PR/Main/Nightly/Release 工作流；
- 四项 PR 说明；
- AI 反例闭环和周期性真实任务抽样；
- Flake 责任人、移除条件和趋势。

退出：开发者与 AI 都能从仓库内确定应补什么、跑什么、如何报告；关键 Lane 在对应时机真实执行。

初步工作量：5–8 人日。

本节的早期 51–80 人日估算已废止，不能用于排期；以第 29 节逐项拆分后的 76–114 人日初估为准，并在 WP2 后重新校准。

### 15.1 预计改动地图

以下是实施搜索和切片边界，不是要求一次全部修改的文件清单。

Apple：

- `Shared/Utilities/AppConstants.swift`：Test Runtime token、Container 内路径和 Release 隔离；
- `Shared/Repositories/LocalDataStore.swift`：Store Factory、会话所有权、readiness 和迁移探针；
- `Shared/UI/AutomationRuntime.swift`：收敛为受限控制面/诊断 Observer；
- `Apps/PushGo-iOS/App/AppEnvironment.swift`、`Apps/PushGo-macOS/App/AppEnvironment.swift`：Composition Root；
- `Apps/*/AppContext.swift`：启动顺序、readiness、teardown；
- `Shared/UI/*ViewModel.swift`：显式 UI State 和业务里程碑；
- `Apps/*/UI/Screens/*`：真实状态渲染和 Accessibility Semantics，移除直接自动化成功发布；
- `Tests/PushGoAppleCoreTests`、`Tests/PushGo-iOSUITests`、`Tests/PushGo-macOSUITests`：新分层用例；
- `scripts/run_ios_ui_tests.sh`、Apple automation scripts、`.github/workflows/*`：动态环境和分级执行。

Android：

- `app/src/main/java/io/ethan/pushgo/data/AppContainer.kt`：Runtime Profile 和依赖组装；
- `app/src/main/java/io/ethan/pushgo/testing/InstrumentationRuntime.kt`：测试运行身份；
- `app/src/debug/.../automation/PushGoAutomation.kt`：拒绝任意路径、显式控制面错误；
- `app/src/main/java/io/ethan/pushgo/data/AppAutomationController.kt`：Seeder/TestIngress 分离；
- `ui/viewmodel/*` 与 `ui/screens/*`：显式状态、语义和真实操作；
- `app/src/test`、`app/src/androidTest`：单元、状态、Store、Feature/UI 迁移；
- `app/build.gradle.kts` 和新的 `macrobenchmark` 模块：Orchestrator、Managed Device、性能；
- `.github/workflows/*` 与 `scripts/*`：PR/Nightly/Release Lane。

仓库治理：

- `pushgo/AGENTS.md`、`pushgo-android/AGENTS.md`：精简 AI/开发质量规则；
- 两仓 `scripts/quality/*`：可执行命令真相；
- 本文或拆分后的仓库本地当前真相：设计与理由，不复制命令实现。

### 15.2 责任边界

- 功能作者/AI：业务代码、最低必要测试、Focused/受影响验证和未运行说明；
- 平台维护者：Test Runtime、设备编排、平台权限/签名和原生 Runner；
- 能力所有者：核心旅程和产品 Oracle，不能由基础设施检查替代；
- 发布责任人：候选包、真实系统、物理设备和授权 Waiver；
- CI：执行和分类，不替产品负责人创造语义；
- AI：可以提出和执行仓库内改动，不能授权跳过、发布、使用生产凭据或改变产品目的。

## 16. 迁移与回滚

1. 新旧测试短期并存，但按能力指定唯一发布 Oracle；旧测试不能与新测试重复计票。
2. 先完成 WP2 样板，再批量迁移，不先删除旧自动化入口。
3. 每迁移一项能力，执行一次真实缺陷扰动，确认新测试失败后再移除旧主 Oracle。
4. Test Runtime 通过构建配置隔离；发现影响生产行为时可回滚 Composition 切换，不回滚业务数据 Schema。
5. 数据库迁移测试使用前向兼容 Fixture；不为测试执行生产数据降级。
6. Runner/CI 改造失败不能阻止现有单元和集成测试继续运行；阻塞 Lane 单独报告。
7. 旧脚本删除前，搜索文档、CI、开发命令和外部调用者，保留明确替代入口。

## 17. 完成标准

方案实施完成必须同时满足：

1. Android/iOS 的核心用户能力均有真实用户结果 Oracle；macOS/watchOS 按其产品能力覆盖适用路径。
2. UI 测试不直接读取 App 私有数据库，不依赖宿主绝对路径交换结果。
3. 慢加载在预算外能够稳定失败，恢复后还验证数据显示正确。
4. 每个关键 Oracle 至少经历一次真实回归、负向 Fixture、扰动/Mutation 或独立交叉验证。
5. 数据输入、源存储、派生状态和用户表面有代表性对账。
6. 环境、产品、Flake 和未运行状态分开；自动重试不洗绿。
7. PR、Nightly、Release 各自执行其承诺的实际 Lane，不只配置脚本。
8. Release 候选包经过升级、真实推送、系统入口和物理设备性能验证。
9. Release 构建不能激活 Test Runtime。
10. AI 在仓库内能找到当前规则和原生命令，代码与必要测试同一切片完成，并报告未运行边界。
11. 不以文件、版本、Identifier、覆盖率、截图生成或报告生成宣称功能通过。
12. 所有旧的主 Oracle 已被替换或明确保留理由；无无人负责的永久 quarantine。

运营目标在 WP2 后校准：Hermetic 环境启动成功率、关键测试 Flake、PR 反馈时长、慢回归检出率和真实系统 `NOT RUN` 时长。它们用于发现体系问题，不合并成单一质量分数。

## 18. 方案可行性与尚未证明的部分

### 18.1 可行性依据

- Apple 已有 XCUITest Target、Automation Context、Fixture Base64、App Environment 和大量 Accessibility Identifier；
- Android 已有自定义 Instrumentation Runner、AppContainer、App Context Store、UIAutomator/Compose 测试；
- 两端已有 GRDB/Room 大数据和迁移测试；
- 已有运行时质量报告暴露具体故障模式；
- CI 已具备 Apple macOS Runner 和 Android SDK 构建基础；
- 改造主要是收敛所有权、Oracle 和执行分层，不要求替换生产数据库或 UI 框架。

### 18.2 当前仍为 `NOT RUN`/待实施验证

- 新 Test Runtime 的连续运行稳定性；
- CI Managed Device 和 Simulator 实际容量、时长与成本；
- 物理设备性能预算；
- 真实 APNs/FCM/Gateway 的发布 Lane 可用性；
- 独立上下文对最终关键 Diff 的红/蓝评审；
- AI 规则在真实开发任务中的漏测率和误阻塞率。

这些缺口不会阻止设计定稿，但必须在对应工作包完成前保持显式，不得提前宣称体系落地。

## 19. 官方依据

- Android 建议按测试范围建立从 Unit、Component、Feature、Application 到 Release Candidate 的分层，并选择能提供正确反馈的最低层：[Android Testing Strategies](https://developer.android.com/training/testing/fundamentals/strategies)
- Gradle Managed Devices 管理设备创建、运行、恢复和关闭：[Scale tests with build-managed devices](https://developer.android.com/studio/test/managed-devices)
- Android Test Orchestrator 隔离 Instrumentation，并可按需清理 Package Data：[AndroidJUnitRunner / Test Orchestrator](https://developer.android.com/training/testing/instrumented-tests/androidx-test-libraries/runner)
- Compose 单向数据流将状态与 UI 解耦，提高独立测试能力：[Compose UI Architecture](https://developer.android.com/develop/ui/compose/architecture)
- Compose 异步测试应使用同步、Idling Resource 或条件等待，而非任意 sleep：[Synchronize Compose tests](https://developer.android.com/develop/ui/compose/testing/synchronization)
- Macrobenchmark 用于从 App 外部测量启动、滚动和真实 UI 操作：[Benchmark your app](https://developer.android.com/topic/performance/benchmarking/benchmarking-overview)、[Write a Macrobenchmark](https://developer.android.com/topic/performance/benchmarking/macrobenchmark-overview)
- Macrobenchmark 的 `StartupTimingMetric`、`FrameTimingMetric` 和 TraceSection 提供 TTID/TTFD、frameOverrun 分布及业务区间证据；性能数字仍需和数据显示正确性组合：[Capture Macrobenchmark metrics](https://developer.android.com/topic/performance/benchmarking/macrobenchmark-metrics)
- WorkManager 用于需跨 App 退出/设备重启保留的可靠工作，支持约束、唯一工作和 backoff；Worker 逻辑和集成分别使用官方测试支持：[Task scheduling](https://developer.android.com/develop/background-work/background-tasks/persistent)、[Testing Worker implementation](https://developer.android.com/develop/background-work/background-tasks/testing/persistent/worker-impl)、[Integration tests with WorkManager](https://developer.android.com/develop/background-work/background-tasks/testing/persistent/integration-testing)
- Compose semantics 同时服务可访问性和测试，但语义树不证明像素或业务副作用，因此必须和任务/数据 Oracle 组合：[Compose semantics](https://developer.android.com/develop/ui/compose/accessibility/semantics)
- XCTest/XCUIAutomation 支持单元、性能和真实 UI 交互验证：[XCTest](https://developer.apple.com/documentation/xctest)
- XCTest 支持 Clock、CPU、Memory、Hitch、Storage 和 Signpost 等指标：[XCTOSSignpostMetric](https://developer.apple.com/documentation/xctest/xctossignpostmetric)
- Apple BackgroundTasks 要求 expiration handler 尽快取消和清理，开发期可在设备上分别模拟 launch/expiration；私有调试调用绝不能进入发布构建：[BGTask expirationHandler](https://developer.apple.com/documentation/backgroundtasks/bgtask/expirationhandler)、[Starting and Terminating Tasks During Development](https://developer.apple.com/documentation/backgroundtasks/starting-and-terminating-tasks-during-development)
- App Intents 可用独立进程方式测试 Intent/Entity/Query，并应再在 Simulator/设备上的 Siri/Shortcuts/Spotlight 系统入口验证；Widget/Control/Live Activity 的交互实际执行 App Intent，且 Extension 与 App 是独立进程：[App Intents Testing](https://developer.apple.com/documentation/AppIntentsTesting)、[Widgets, Live Activities, and Controls](https://developer.apple.com/documentation/appintents/widgets-live-activities-and-controls)、[Adding interactivity to widgets and Live Activities](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities)
- Apple Sandbox 要求 App 主要访问自己的 Container，跨 Container 需要明确权限或 App Group：[Protecting user data with App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)、[Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- Apple 建议从主要用户任务出发，在各支持设备和辅助技术上验证可访问性：[Performing accessibility testing](https://developer.apple.com/documentation/accessibility/performing-accessibility-testing-for-your-app)

## 20. 紧接着执行的第一步

实施不从搭 CI 报表开始，而从 WP0 + WP1 的最小前置和 WP2 的纵向样板开始：

1. 生成现有测试“保留/重写/删除/基础设施”清单；
2. 在 Apple/Android 定义最小 Runtime Profile 和 App 自有会话 Store；
3. 选择“接收一条消息并显示，慢加载会失败，恢复后内容正确”作为第一条能力；
4. 在旧实现上建立失败或受控扰动；
5. 完成两端新路径和原生执行入口；
6. 连续运行并归因所有首错；
7. 样板通过红方钻空子检查和蓝方集成检查后，再扩展其他能力。

这条样板决定后续架构。如果它仍需要直接数据库、状态文件或人工权限准备，WP1 不得宣布完成。

---

## 21. 实施规格的优先级与完成定义

第 1–20 节说明目标、边界和设计理由；第 21–33 节把它落实为工程任务。如有表达冲突，以第 21–33 节的具体接口、范围、测试清单和退出条件为准。

### 21.1 最终应在仓库中出现的产物

```text
pushgo
├── App-owned Quality Runtime（Debug/UITest/Performance 可用，Release 不可激活）
├── 按能力拆分的 Core/Store/UI/Performance/System tests
├── docs/quality/capability-coverage.md（轻量防漏索引，不作为通过 Oracle）
├── Quality-PR / Quality-Nightly / Quality-Release test plans
├── scripts/quality/{doctor,focused,pr,nightly,release}.sh
└── 精简 AGENTS.md + PR 质量说明

pushgo-android
├── Runtime Profile + Test Application + App-owned session database
├── JVM/Room/Compose/UIAutomator/Device tests
├── docs/quality/capability-coverage.md（轻量防漏索引，不作为通过 Oracle）
├── macrobenchmark + baselineprofile 模块
├── Gradle Managed Devices + Test Orchestrator
├── scripts/quality/{doctor,focused,pr,nightly,release}.sh
└── 精简 AGENTS.md + PR 质量说明
```

### 21.2 硬性完成条件

只有以下条件全部满足，才可以说改造完成：

1. 第 25 节所有 P0 用例在适用平台已实现并有新鲜执行证据；
2. 所有 P1 用例已实现，或有明确延期原因、负责人和截止时间；
3. Apple UI 测试不再让 App 读取 Runner 创建的 Fixture、DB、state、event 或 response 绝对路径；
4. Android UI 测试不再通过任意路径交换最终判定状态；
5. Hermetic 启动连续 50 次成功率不低于 98%，不一致结果保持 `FLAKY`；
6. UI 用例最终断言来自可见内容、可继续操作和必要的重启结果；
7. 慢加载负控稳定让性能测试失败，错误字段负控稳定让数据显示测试失败；
8. Release 构建无法解析或激活 Quality Runtime；
9. PR/Nightly/Release Lane 连续运行两周，P0 没有被隐藏的 `BLOCKED/NOT RUN`；
10. AI 在历史真实任务样本上能正确补测、选测、执行和报告，不能靠 skip、重试或弱化断言变绿。
11. 第 32 节的双向覆盖检查没有未解释的“源码能力无测试”或“测试目标在产品中不可达”；
12. 第 33 节列出的设备、窗口、后台和系统表面门禁均有 `PASSED`，或按其允许的 Lane 明确记录 `BLOCKED/NOT RUN`，P0 Release 不得缺席。

## 22. 当前测试的逐类处置

### 22.1 静态盘点事实

| 资产 | 当前规模/形态 | 主要失真点 | 处置 |
| --- | --- | --- | --- |
| `Tests/PushGoAppleCoreTests` | 40 个 Swift 文件，约 389 个 `@Test` | 很多强测试未映射到用户能力 | 保留，补能力索引和缺口 |
| iOS UI 单文件 | `PushGo_iOSUITests.swift` 当前 2,268 行 | Fixture、导航、状态、性能和截图混合 | 拆分并重写最终 Oracle |
| macOS UI 单文件 | `PushGo_macOSUITests.swift` 当前 1,815 行 | artifact 不可用时可能提前返回 | 删除静默通过，按能力拆分 |
| `AutomationRuntime.swift` | 当前 3,584 行 | 能导航、写数据、发布状态、测性能 | 缩成 Runtime 初始化与诊断，最终退役命令面 |
| Android JVM | 49 个文件，约 269 个 `@Test` | 强低层测试缺能力到门禁映射 | 保留并纳入 Focused/PR |
| Android device | 21 个文件，约 75 个 `@Test` | UI、数据、Gateway、诊断职责混合 | 按 Store/Platform/UI/Real 分开 |
| Android Automation | debug/release bridge + controller | 任意路径、best-effort 写、内部 state Oracle | 删除路径协议，release 保持空并加负测 |
| 两端 CI | 构建/发布检查较强 | PR 没有稳定的 P0 用户旅程 | 新增分级 Quality jobs |

### 22.2 现有用例处理规则

| 现有模式 | 处理 | 新的最终判定 |
| --- | --- | --- |
| `testLaunchesIntoMessageList` | 重写保留 | 首屏是 Empty/Content/Error 中的正确状态，并可导航，不只是 screen id |
| `nav.switch_tab` 自动命令 | 回归用例删除；截图准备可保留 | UI 回归真实点击 Tab/Sidebar |
| `fixture.seed_*` 后检查 import count | 移到 Runtime/Store 集成测试 | UI 必须显示准确行和字段 |
| `AutomationState.visibleScreen/count` | 仅诊断 | 可见元素、对象 id、字段、顺序、交互和重启 |
| `guard automationArtifactsAvailable else { return }` | 删除 | Hermetic 直接 fail；整套外部 Lane 不可用才显式 skip/block |
| `runtime.measure_*` | 拆分 | Store benchmark + XCTMetric/Macrobenchmark，均带正确性守护 |
| Android `RuntimeDataLayerInstrumentedTest` | 保留、拆文件 | 只证明 Room/平台数据层，不声称 UI |
| Android Runtime Compose/UIAutomator | 保留真实点击，重写 state 判定 | 用户可见内容与后续行为 |
| Migration tests | 保留扩展 | 旧库升级、reopen、真实页面可用 |
| Accessibility semantics | 保留扩展 | 从有 label 扩展到关键任务可完成 |
| Gateway/FCM diagnostics | 独立 Lane | synthetic contract 与 real-system 分开 |
| 截图生成 | 与回归判定分开 | 差异需人审，不允许自动更新即通过 |

WP0 必须生成两个仓库各自的 `docs/quality/current-test-disposition.md`，逐个现有 UI/device 测试标记 `keep/rewrite/move/delete/diagnostic`。这张表是迁移清单，不是永久 Manifest；迁移完成后可归档。

## 23. 可直接编码的 Quality Runtime 设计

### 23.1 Runtime Profile

两端共享语义，使用原生实现：

| Profile | 依赖 | 允许的测试接入 | 主要用途 |
| --- | --- | --- | --- |
| `production` | 正式 Store/网络/OS | 无 | 正式 App |
| `hermetic` | App 自有 Store、确定 Scenario、Fake boundary | seed/fault/readiness | PR UI/集成 |
| `contract` | 真 App + sandbox | sandbox endpoint/test account | Nightly 合同 |
| `performance` | Release-like/profileable + 确定数据 | seed + signpost，不允许业务捷径 | 性能 |
| `realSystem` | 候选包、真实 OS、测试账号 | 不允许 Test Runtime | 发布 |

Apple 新增接口：

```swift
enum QualityRuntimeProfile: String, Sendable {
    case production, hermetic, contract, performance
}

struct QualitySessionDescriptor: Decodable, Sendable {
    let schemaVersion: Int
    let sessionID: UUID
    let scenario: String
    let seed: UInt64
    let scale: Int?
    let faultPlan: QualityFaultPlan?
}

@MainActor
extension AppEnvironment {
    static func make(
        profile: QualityRuntimeProfile,
        session: QualitySessionDescriptor?
    ) async throws -> AppEnvironment
}
```

Android 新增接口：

```kotlin
enum class RuntimeProfile { Production, Hermetic, Contract, Performance }

@Serializable
data class QualitySessionDescriptor(
    val schemaVersion: Int,
    val sessionId: String,
    val scenario: String,
    val seed: Long,
    val scale: Int? = null,
    val faultPlan: QualityFaultPlan? = null,
)

fun AppContainer.Companion.create(
    application: Application,
    profile: RuntimeProfile,
    session: QualitySessionDescriptor?,
): AppContainer
```

### 23.2 Runtime 允许和禁止的能力

允许：

- 根据 allowlist 中的 `scenario + seed + scale` 在 App 自己的容器生成数据；
- 选择独立 Store 名称/URL；
- 替换 Clock、Gateway transport、permission facade 等明确边界；
- 注入声明过的 delay/failure/duplicate/out-of-order；
- 发布 `booting/storeReady/seeded/appReady/failed` readiness；
- 输出不含业务正文和凭据的里程碑诊断。

禁止：

- 任意绝对路径、任意 SQL、任意 URL、任意导航；
- 直接设置 ViewModel/UI 的成功状态；
- 直接写最终 Automation State 并作为产品通过；
- 绕过 Parser/Coordinator 后声称 APNs/FCM/private 正常；
- 在 Release source set/编译条件中保留可激活入口。

### 23.3 跨沙箱问题的最终解决方式

1. Runner 只通过 launch argument/intent 传小型 base64 `QualitySessionDescriptor`；
2. 大数据由 App 内 generator 生成，不传大 JSON；
3. 少量边界 Fixture 编译进 Test Support bundle，由 App 自己读取；
4. Apple 的 session DB、Fixture 展开和诊断文件全部位于 App 自己 Container；Runner 不直接打开；
5. Android 使用 target app Context 创建独立 DB；不使用 test APK Context 的 DB；
6. readiness 可通过非交互语义节点或 target instrumentation 读取，但只能证明准备完成；
7. 最终结果必须通过真实 UI/系统入口和必要的 relaunch 验证；
8. 诊断进入 `xcresult`、logcat 和 trace attachment，不再依赖 state file；
9. 任何准备失败 10 秒内以结构化错误结束，不能等到元素 30 秒超时才暴露。

### 23.4 固定生命周期

```text
doctor/preflight
-> 分配 session id、设备和唯一 build/result 目录
-> 安装并启动 App
-> App 创建自己的 Store、migration、seed
-> readiness=appReady
-> 测试执行真实操作
-> 断言可见结果和必要的 durable 结果
-> 保存首错、截图、最小日志/trace
-> terminate、停止后台任务、清 session/通知/缓存
-> 确认设备可复用
```

### 23.5 受控 Fault Plan

| 故障 | 注入位置 | 需要证明 |
| --- | --- | --- |
| `firstPageDelay(ms)` | Repository 查询前 | Loading、预算、最终内容 |
| `nextPageDelay(ms)` | Paging boundary | 保留旧内容、不重复请求 |
| `storeOpenFailure(code)` | Store Factory | 致命启动错误、停止读写、诊断与产品批准的恢复/退出动作；只有确实可恢复的错误才要求 Retry |
| `queryFailure(call,count)` | Repository | 错误状态和恢复 |
| `gatewayDelay(ms)` | Fake/Sandbox transport | 网络慢/超时；不代表公网性能 |
| `gatewayStatus(code)` | Transport | 鉴权/限流/服务错误映射 |
| `dropAck(count)` | ACK transport | durable retry/幂等 |
| `duplicateDelivery(count)` | TestIngress | canonical 去重 |
| `outOfOrderDelivery` | TestIngress | Event/Thing 最终投影 |
| `processKillCheckpoint` | Runner | 进程死亡恢复 |

故障必须注入到生产边界，不允许通过 UI `sleep` 或直接改 UI state 模拟。

## 24. UI/业务代码必须配合的改造

### 24.1 显式页面状态

Message List、Search、Detail、Event/Thing、Channels、Settings 至少表达：

```text
idle
loading(previousContent?)
content(data, freshness)
empty
partial(data, nonBlockingError)
error(recoverable, userMessage)
retrying(previousContent?)
```

页面按自身需要删减，不能再用 `items.isEmpty` 同时表示“未加载”和“确实为空”。首次加载、分页、后台刷新必须分开；旧请求覆盖新请求、错误被吞成永久 Loading 都必须能被状态测试捕获。

### 24.2 可注入非确定性边界

生产代码只为真实变化点保留窄接口：

- `Clock/Sleeper`：Undo、backoff、debounce、超时；
- `StoreFactory`：生产 DB 与 session DB；
- `GatewayTransport`：真网络、fake、sandbox；
- `PermissionFacade`：业务分支；系统权限另测；
- `NotificationPublisher`、`Clipboard`、`ExternalURLLauncher`、`UpdateInstaller`；
- `MilestoneRecorder`：生产可为轻量 signpost；
- `FaultInjector` 只在测试构建存在。

不创建一个包含全部 App 操作的巨型 `TestableApp` 协议。

### 24.3 UI 语义规则

每个主屏、主要动作、动态行和关键状态提供稳定语义：

```text
screen.messages.list
state.messages.loading / empty / error
message.row.<stable-id>
action.message.delete
action.messages.filter
screen.message.detail
screen.events.list / screen.events.detail
screen.things.list / screen.things.detail
screen.channels
screen.settings
```

Identifier 只帮助定位；断言必须继续检查名称、值、状态、集合、交互和持久化结果。

### 24.4 业务里程碑

两端统一语义、原生实现：

```text
app.launch.requested
store.open.started / ready / failed
scenario.seed.started / completed / failed
ui.first_frame
ui.first_meaningful_content
ui.screen.interactive
search.submitted / results.visible
detail.requested / content.visible
ingress.accepted / persisted / projected / notification.posted
mutation.requested / persisted / reflected
```

Apple 用 `os_signpost`/XCTMetric；Android 用 trace/Macrobenchmark。里程碑用于归因和性能，不能替代功能 Oracle。

## 25. 当前功能必须包含的详细测试清单

标记：`A` Apple Core/共享，`I` iOS，`M` macOS，`W` watchOS，`D` Android。优先级与执行 Lane 分开：`P0` 是发布阻断能力，快速且稳定的 P0 必须进 PR，其余平台 P0 至少 Nightly 且 Release 汇总前证据仍有效；显式 `P0 Release` 只在发布物理/真实系统 Lane 执行。`P1` 默认 Nightly，显式 `P1 Release` 进入发布 Lane；`P2` 周期/人工辅助。测试名直接描述行为，不另建永久编号系统。

### 25.1 启动、Store、迁移、恢复

| 级别 | 必测行为 | 平台/层 | 最终 Oracle |
| --- | --- | --- | --- |
| P0 | 新安装冷启动 | I/M/D UI | 正确 Empty/Content，可导航，无永久 Loading |
| P0 | 标准数据冷启动 | I/M/D UI | 行 id、标题、频道、时间、未读与 Scenario 一致 |
| P0 | Store 慢 2 秒 | VM + I/M/D UI | 明确 Loading 后显示正确内容 |
| P0 | 页面查询/暂时 I/O 失败再 Retry | VM + I/M/D UI | 错误可理解；Retry 发起新请求并真恢复，旧错误不冒充内容 |
| P0 | 致命 Store 初始化失败 | A/D Store + I/M/D UI | 停止读写；原因和安全退出/诊断/产品批准的恢复动作准确，不伪装 Empty，不强行要求不存在的 Retry |
| P0 | 每个受支持 schema 升级 | A/D Store | 消息、设置、频道、ACK/deletion 全保留 |
| P0 | migration 后 reopen | A/D Store | 当前 schema 和数据可再次打开 |
| P1 | migration 中进程终止 | A/D Store | 下次安全恢复/重试，无损坏 |
| P1 | 索引缺失/陈旧 | A/D Store + UI | 主列表可用，索引最终追平 revision |
| P1 | 磁盘满/写失败 | A/D Store | 显式失败，无半条数据/错误统计 |
| P0 | session teardown 隔离 | I/M/D UI | 下一测试无消息、通知、权限、缓存残留 |
| P0 | Release Runtime 负测 | I/M/D packaged | descriptor 无法激活测试能力 |

### 25.2 导航与页面可见性

| 级别 | 必测行为 | 平台/层 | 最终 Oracle |
| --- | --- | --- | --- |
| P0 | 点击 Messages/Events/Things/Channels/Settings | I/M/D UI | 显示目标页独有内容并能返回/切换 |
| P0 | 关闭 Events/Things 页面 | VM + I/M/D UI | 入口消失，其他页和当前选择合法 |
| P0 | 重启后可见性保留 | I/M/D UI | 设置仍生效 |
| P1 | 当前 Messages Tab 单击/双击 | I/D UI | 单击滚到首个未读；双击滚到顶部；280/320ms 判定不误触发、不遗留任务 |
| P1 | 当前 Events/Things Tab 双击 | I/D UI | 滚到对应列表顶部，不切换对象或触发 Messages 行为 |
| P0 | 导航未读 Badge | I/M/D UI | count、99+、mark read/delete/ingress 后同步，隐藏页面不误挂入口 |
| P1 | macOS Sidebar 键盘导航 | M UI | 焦点、选中和详情分栏一致 |
| P1 | 冷启动 Deep Link/通知目标 | I/M/D platform UI | 打开准确对象，不只进入 App |
| P1 | 无效/已删除目标 | I/M/D UI | 合法 fallback，无空白/旧详情 |

### 25.3 Message List、分页、筛选、刷新

| 级别 | 必测行为 | 平台/层 | 最终 Oracle |
| --- | --- | --- | --- |
| P0 | 空库 | I/M/D UI | Empty 引导，不是 Loading |
| P0 | 标准列表字段 | I/M/D UI | 标题、摘要、频道、时间、severity、已读准确 |
| P0 | 125 条分页 | Store + I/D UI | 全部加载，无丢失/重复/错序 |
| P0 | 相同时间 tie-break | A/D property/store | reload 后顺序稳定 |
| P1 | 下页慢 | I/D UI | 旧内容保留、底部进度、不重复请求 |
| P1 | 下页失败重试 | I/D UI | 旧内容保留，恢复后只追加一次 |
| P0 | 未读筛选 | I/M/D UI | 只显示未读，数量与集合一致 |
| P0 | 频道筛选 | I/M/D UI | 只显示目标频道，ungrouped 正确 |
| P0 | Tag/组合筛选 | I/M/D UI | 集合语义正确，清除后恢复 |
| P1 | 其他已实现 facet | I/M/D UI | 每个选项改变真实集合，不只改变 chip |
| P0 | Refresh 成功 | I/M/D UI | 新消息出现，无旧结果覆盖 |
| P1 | Refresh 失败 | I/M/D UI | 旧内容保留，非阻断错误可重试 |
| P0 | 单条 Mark read | I/M/D UI | 行和计数改变，重启仍已读 |
| P0 | 当前范围 Mark all read | I/M/D UI | 只改当前范围，其他不变 |
| P1 | Apple 消息行辅助动作：复制标识/打开 | I/M platform UI | 目标行正确；剪贴板精确；打开的是该行详情，不把辅助动作存在误判成 Android 也已实现 |
| P1 | Android 消息行点击、Mark read、Delete 辅助语义 | D UI/a11y | 点击打开准确详情；已读和删除动作作用于目标行；不虚构当前不存在的复制动作 |
| P0 | 删除并 Undo | I/M/D UI | 同一对象和顺序恢复 |
| P0 | 删除不 Undo | I/M/D UI | deadline 后真删除，重启不复活 |
| P1 | 清理已读/当前频道 | Store + I/M/D UI | 只删除声明范围；其他频道、未读、统计和搜索不受误伤 |
| P1 | 历史清理 All/7d/30d/3m/6m/1y | Store + I/M/D UI | 每个 cutoff 边界、时区/DST、确认/取消、Cleaning、成功数量、失败重试均准确 |
| P1 | 10k 滚动 | I/M/D performance | 正确性守护 + 卡顿预算 |

### 25.4 Search

| 级别 | 必测行为 | 平台/层 | 最终 Oracle |
| --- | --- | --- | --- |
| P0 | 空 query | A/D unit + UI | 当前产品定义的占位/全集行为准确 |
| P0 | 大小写、音调、全半角、标点、CJK | A/D property + UI 代表例 | 返回准确集合 |
| P0 | 标题/正文/频道/tag/metadata 范围 | A/D Store | 命中范围符合产品语义 |
| P0 | 快速连续输入 | A/D VM | 旧请求取消，只显示最新 query |
| P0 | 慢搜索 | I/M/D UI | 搜索进度可见，导航不卡死 |
| P1 | 失败与 Retry | I/M/D UI | 旧结果不冒充新结果，恢复正确 |
| P0 | 无结果/清除 | I/M/D UI | query 空态准确，清除恢复 |
| P0 | 打开搜索结果 | I/M/D UI | 详情 id/字段与结果一致 |
| P1 | 索引 rebuilding | I/M/D UI | 状态诚实，不静默漏结果 |
| P1 | 10k/100k 搜索性能 | Store benchmark + UI | 集合正确 + 延迟预算 |

### 25.5 Message Detail、Markdown、媒体、解密

| 级别 | 必测行为 | 平台/层 | 最终 Oracle |
| --- | --- | --- | --- |
| P0 | 从列表打开详情 | I/M/D UI | id、标题、正文、频道和列表对象一致 |
| P0 | 打开后已读语义 | I/M/D UI | 详情/列表/计数同步并持久化 |
| P0 | Markdown 表格/列表/链接/代码/引用/任务 | parser + UI | 主要语义结构正确，不只存在 Text |
| P1 | 超长正文/Unicode/长行 | I/M/D UI | 可滚动返回，无截断/崩溃/长卡顿 |
| P1 | 外部链接安全 | I/M/D platform | 合法可开，危险/非法拒绝 |
| P1 | Copy link/metadata | I/M/D platform UI | 剪贴板内容精确 |
| P1 | 图片成功/占位/失败/重试 | I/M/D UI | 各状态可见，失败不阻塞正文 |
| P1 | 图片全屏预览/关闭 | I/M/D UI | 打开目标原图；关闭后回到原对象和滚动位置，下载/动画/手势任务停止 |
| P1 | 图片缩放/平移 | I/M/D UI | 1–4 倍和边界约束准确，不影响关闭、返回和辅助操作 |
| P1 | 图片保存/分享 | I/M/D platform | 成功文件可被消费者读取，MIME/扩展名正确；取消/权限/I/O 失败不显示假成功 |
| P1 | GIF/APNG 生命周期 | I/M/D UI/perf | 离屏/退出停止，返回不持续泄漏 |
| P0 | 合法 Key 解密 | A/D unit + UI | 正确明文和状态 |
| P0 | 缺 Key | I/M/D UI | 原因和设置入口准确 |
| P0 | 错 Key/损坏密文 | A/D unit + UI | 不显示垃圾明文，可恢复 |
| P1 | 加载中对象被删除 | VM + UI | 安全返回/缺失提示，无错配 |
| P0 | 详情删除、Undo、relaunch | I/M/D UI | 与列表删除语义一致 |
| P1 | 详情往返 20 次 | I/M/D perf | 内存回落、媒体/任务停止、无持续退化 |

### 25.6 Events

| 级别 | 必测行为 | 平台/层 | 最终 Oracle |
| --- | --- | --- | --- |
| P0 | 空态/标准列表 | I/M/D UI | 状态、标题、时间、摘要准确 |
| P1 | Events/Things 引导型空态 | I/M/D UI | 引导步骤、文档/设置动作和页面类型一致；动作真能到达可完成下一步的位置，不只检查插图或文案存在 |
| P0 | active/resolved、patch、乱序 | A/D property/store | canonical head 正确 |
| P0 | 搜索 title/summary/message/status/severity/tags/eventId/thingId/channelId/timeline id | Store + UI 代表例 | 只命中产品实际支持字段；不凭空声称未实现的 metadata 搜索 |
| P1 | Channel/Tag/只看未关闭筛选 | I/M/D UI | 每个选项真实改变集合和数量，组合/清除后准确恢复 |
| P1 | 刷新、分页、慢/错 | I/M/D UI | 旧内容保留，状态转换正确，无丢失/重复/旧请求覆盖 |
| P0 | 详情和时间线 | I/M/D UI | 头字段和历史顺序/内容准确 |
| P1 | Apple Event 行辅助打开/复制/删除 | I/M platform UI/a11y | 每个动作作用于目标 Event，复制精确 id；Android 只验证当前真实提供的打开/关闭/删除语义，不虚构复制 |
| P0 | 关闭事件确认/取消/成功 | I/M/D UI + contract | 取消无副作用；成功后列表、详情、时间线、筛选和 Thing 关联视图一致 |
| P0 | 关闭事件失败/重复提交 | VM + integration + UI | 失败仍为未关闭且可重试；重复响应幂等，关闭后动作隐藏/禁用 |
| P1 | 从 Thing 关联 Event 关闭/删除 | I/M/D UI | 关联 Sheet 与 Event 主列表收敛，返回 Thing 后页签/对象不丢失 |
| P1 | tombstone/字段清除 | Store + UI | 旧字段不从历史复活 |
| P1 | 单条/批量/频道删除与 Undo | Store + UI | 有效范围和关联数据一致 |
| P0 | macOS 分栏选择/删除 | M UI | 选择、详情和删除后 fallback 合法 |
| P1 | 10k 投影性能 | benchmark + UI | 正确性守护 + 预算 |

### 25.7 Things

| 级别 | 必测行为 | 平台/层 | 最终 Oracle |
| --- | --- | --- | --- |
| P0 | 空态/标准列表 | I/M/D UI | 名称、状态、摘要、图片准确 |
| P1 | Events/Things 引导型空态 | I/M/D UI | 引导步骤、文档/设置动作和页面类型一致；动作真能到达可完成下一步的位置，不只检查插图或文案存在 |
| P0 | patch/乱序 canonical head | A/D property/store | 旧更新不覆盖新 head |
| P0 | 搜索 location/external id/attrs/关联文本 | Store + UI | 命中准确 |
| P0 | 详情概览与真实 Tabs | I/M/D UI | 概览字段准确；Events/Messages/Updates 三个页签集合、顺序和空态准确，不把 attrs 当成页签 |
| P0 | tags/location/metadata | I/M/D UI | 值、空态、清除正确 |
| P1 | 只看 Active、Channel/Tag 筛选 | I/M/D UI | 状态、频道、标签及组合筛选集合准确 |
| P1 | 关联 Event/Message/Update 打开 | I/M/D UI | 打开正确对象；返回仍是原 Thing 和原页签，无对象串页 |
| P1 | Apple Thing 行辅助打开/复制/删除 | I/M platform UI/a11y | 每个动作作用于目标 Thing，复制精确 id；Android 只验证当前真实提供的打开/删除及关联内容动作 |
| P1 | Metadata Sheet/图片预览 | I/M/D UI | Sheet 值和空态准确；预览目标、关闭和恢复位置正确 |
| P1 | Deep Link/通知直接打开指定 Thing 页签 | I/M/D platform UI | 目标 id 和页签准确；非法页签 fallback 合法 |
| P1 | tombstone 清除 | Store + UI | UI/搜索不再显示旧值 |
| P1 | 图片/动图 | I/M/D UI/perf | 生命周期与 Message 一致 |
| P1 | 单条/批量/频道删除与 Undo | Store + UI | pending 数据不复活已删对象 |
| P0 | macOS 分栏选择 | M UI | 选择与详情一致 |

### 25.8 Channels

| 级别 | 必测行为 | 平台/层 | 最终 Oracle |
| --- | --- | --- | --- |
| P0 | 空态和入口 | I/M/D UI | 创建/订阅可达 |
| P0 | 名称/ID/密码边界 | A/D unit + UI | trim、控制字符、长度、易混字符准确 |
| P1 | 创建成功 | I/M/D contract UI | 新频道出现、重启保留、远端一致 |
| P1 | 订阅成功 | I/M/D contract UI | 行出现且目标路由生效 |
| P0 | duplicate/auth/limit/not-found 错误 | VM + UI | 错误文案和恢复动作准确 |
| P1 | provider/private 切换 | integration | 同时只有目标通道 active |
| P1 | 切换中进程终止 | integration | 重启一致，无双 active |
| P0 | 点击行复制 Channel ID | I/M/D platform UI | 剪贴板精确等于目标 ID，不复制别名或截断值 |
| P0 | 重命名成功/取消/非法/失败 | I/M/D contract UI | 取消不改；trim/空白准确；成功远端与本地一致并持久；失败保留旧名可重试 |
| P0 | 删除确认取消 | I/M/D UI | 本地/远端均未改 |
| P0 | 退订并保留历史 | I/M/D contract UI | 不再接收新消息；既有 Message/Event/Thing/搜索仍可读；重启后保持 |
| P0 | 退订并删除历史 + Undo | I/M/D UI | Undo 期不触发最终远端删除；关联数据恢复一致 |
| P1 | 两种退订并发/互斥 | integration | 同一 Channel 不会同时排队“保留”和“删除历史”，最终终点唯一 |
| P1 | 删除提交、断网、恢复 | integration + UI | durable pending、幂等、最终一致 |
| P1 | 删除期间 Gateway 切换 | integration | 不误删新版本订阅 |
| P0 | Channel 行统计 | I/M/D UI | total/unread/latest 与实际消息一致 |

### 25.9 Settings 与平台特有设置

| 级别 | 必测行为 | 平台/层 | 最终 Oracle |
| --- | --- | --- | --- |
| P0 | Gateway URL 合法/非法/规范化 | unit + I/M/D UI | 保存准确，非法 inline feedback |
| P1 | Gateway 编辑取消/保存失败 | I/M/D UI + contract | 取消保持旧配置；失败保留旧配置并可重试，不因关闭 Sheet 提前改变真实请求 |
| P1 | Apple Gateway 恢复默认 | I/M UI | 控件只修改编辑值；确认保存后才切换真实 endpoint，取消仍保留旧配置 |
| P0 | Token 显示/隐藏/安全保存 | secure store + UI | 不泄露，relaunch 有效，失败明确 |
| P1 | Gateway 修改影响后续请求 | contract | 请求真到新 endpoint，不只值变化 |
| P0 | Page visibility | I/M/D UI | 入口与 relaunch 状态准确 |
| P0 | 解密 Key hex/base64 边界 | unit + UI | 编码、长度、空值准确 |
| P0 | 保存 Key 后恢复消息 | I/M/D UI | 原失败消息显示正确明文 |
| P1 | 通知声音优先级规则 | A platform/unit + I/M UI | critical/high/normal/low 各自 system/silent/builtin/custom 模式和默认值准确 |
| P1 | 通知声音选择/时长/增益/保存 | A platform + I/M UI | 选择、步进边界、relaunch 和真实通知生效，平台差异准确 |
| P1 | 通知声音预览/停止/切换 | A platform + I/M UI | 只播放当前选择；再次点击/离开页面/切换项目会停止，无重叠泄漏 |
| P1 | 自定义声音导入/删除 | A platform + I/M UI | 文件类型/空文件/过大/不可读准确失败；删除确认、被规则引用时的 fallback 和重启一致 |
| P1 | macOS 声音目录权限 | M platform UI | 未授权、授权、撤销、路径失效均有真实状态和恢复动作 |
| P0 | 全部可见文档链接 | I/M/D UI | Getting Started、Message API、E2EE 等当前可见入口分别打开本地化且安全的目标；错误能反馈，不以 URL 字符串存在判通过 |
| P0 | 通知权限设置卡片 | I/M/D platform UI | notDetermined/denied/authorized 显示和动作准确；系统设置返回后刷新，不把拒绝当 App 失败 |
| P1 | iOS Watch receiver resync | I/W integration | 状态真实同步，不只 state 字段 |
| P1 | macOS Launch at Login | M platform | 系统项真实启停、失败可见 |
| P1 | macOS update/beta | M UI/contract | 候选、无更新、错误、beta 切换正确 |
| P0 | Android FCM/Private Transport 选择 | D UI/integration | 可用性/whitelist/状态文案准确；服务、token、连接和后续消息真实切换 |
| P1 | Android Doze 引导/一个月免提醒 | D physical/UI + unit | 进入正确系统设置；返回刷新；snooze 到期前不骚扰、到期恢复 |
| P1 | Android 自动更新/Stable-Beta/手动检查 | D UI/worker/contract | Worker 真正启停；候选集合、检查中、无更新、错误和渠道切换准确 |
| P1 | Android 更新 Install/Later/Skip | D UI + policy | install 进入安装链；later 按 24h/72h/7d；skip 只屏蔽目标版本，手动/关键更新按策略绕过 |

### 25.10 Ingress、通知、ACK、系统路由

| 级别 | 必测行为 | 平台/层 | 最终 Oracle |
| --- | --- | --- | --- |
| P0 | plain/encrypted payload | A/D unit/property | canonical fields/明文或明确失败 |
| P0 | 非法/过期/未知 payload | A/D unit | 安全拒绝，无半成品 |
| P0 | FCM/private 同 canonical id | integration | 主消息恰好一条 |
| P0 | 同入口重复 delivery | integration | 不重复消息、通知、统计 |
| P0 | Event/Thing 乱序 | integration | 最终投影正确 |
| P0 | persist 成功、ACK 失败 | integration | 消息可见，ACK durable pending |
| P0 | persist 失败 | integration | 不 ACK/不发成功通知，可重试 |
| P1 | ACK retry + process death | integration | 恢复后 exactly-once 语义 |
| P1 | 通知字段/前台策略 | I/M/D platform | 标题、正文、声音、badge/channel 准确 |
| P1 | 前台位于列表顶部的通知抑制 | I/M/D platform/UI | 仅在产品声明的顶部/详情条件抑制重复展示；滚离顶部、切页和后台后恢复 |
| P1 | severity 声音生命周期 | I/M/D platform | critical/high/normal/low 模式、抢占、定时停止和重复通知准确 |
| P0 Release | 通知点击冷/热启动 | physical UI | 打开准确详情，无重复导航 |
| P1 Release | Open related entity action | I/M/D physical UI | Message/Event/Thing 关联目标准确；缺失/已删目标合法 fallback |
| P0 Release | Mark read/delete/copy action | physical UI | 通知、DB、列表、badge/剪贴板一致 |
| P1 Release | 通知划除/打开/已读/删除后清理 | physical | 平台定义的已读、通知移除、声音停止、前台服务状态均一致 |
| P0 Release | 权限拒绝/允许 | I/D physical | App 可用、引导准确、允许后 token/通知正常 |
| P0 Release | 真实 APNs | I physical | Provider→device→DB→UI 完整 |
| P0 Release | 真实 FCM | D physical | FCM→service→DB→UI 完整 |
| P0 Release | 真实 Private Channel | I/M/D real | sandbox→transport→ACK→UI 完整 |

### 25.11 持久删除、Undo、恢复

| 级别 | 必测行为 | 平台/层 | 最终 Oracle |
| --- | --- | --- | --- |
| P0 | Undo 窗口恢复 | coordinator + UI | 原对象/统计恢复 |
| P0 | Undo 过期提交 | coordinator + UI | 真删除，relaunch 不复活 |
| P0 | 后台转换提交 | lifecycle | 不冻结倒计时，提交一次 |
| P0 | pending 时杀进程 | reopen | 重启按时间语义恢复/提交 |
| P1 | claim 后杀进程 | reopen | claim 可回收，无丢失/重复副作用 |
| P1 | 远端失败/backoff/recovery | integration | 后续可恢复操作不被永久阻塞 |
| P1 | permanent conflict | integration | 不误删新版本，最终错误准确 |
| P1 | 多 pending 并发 | concurrency | 无重复 claim、顺序边界正确 |

### 25.12 导出候选能力、Apple 系统表面、Android 更新

| 级别 | 必测行为 | 平台/层 | 最终 Oracle |
| --- | --- | --- | --- |
| P0 | 导出能力可达性裁决 | source + product review | 当前三端实现代码若无真实 UI/系统入口，必须明确选择“接通为受支持功能”或“删除未使用实现”；不得因类/文件存在就宣称已提供导出 |
| P0 | 保留后的导出 JSON shape | A/D unit | 字段、编码、raw payload、稳定性准确；仅在可达性裁决为保留后成为门禁 |
| P1 | 保留后的大数据流式导出/取消/失败 | integration/perf | 不全量载入，无残缺成功文件；取消或失败不发出成功事件 |
| P1 | 保留后的系统分享/文件 Picker | I/M/D platform | 从真实用户入口完成任务，外部消费者可读取目标文件；不是直接调用 helper |
| P1 | Unread/Critical Event/Object Status Widgets | A integration + system UI | 各自 count/对象/空态/尺寸准确，与主库 revision 一致且无隐私泄露 |
| P1 | watch complication | W integration + system UI | unread snapshot、刷新时间线、点击路由和过期 fallback 准确 |
| P1 | 5 个 Control Widgets | I platform | 打开 Messages/Events/Objects/最近严重事件和标记最新未读的目标及副作用分别准确 |
| P1 | Open Message/Event/Thing/List Intents | A platform | 参数解析、精确目标、目标缺失和 list fallback 准确 |
| P1 | Summary/Count/Query Intents | A platform | recent/unread/critical/object 摘要和计数来自真实集合，空态/截断/本地化准确 |
| P1 | Mark Read/Best Match Intents | A platform | 标记目标消息并同步 Widget/badge；best match 选择策略和无候选结果准确 |
| P1 | App Shortcuts 注册与代表短语 | A physical/system | 10 个当前 Shortcut 可发现，代表中英文短语调用正确 Intent；不以结构体存在判通过 |
| P1 | Spotlight/User Activity | A platform | index/update/delete/rebuild、点击路由、失效目标和敏感正文/metadata 隐私准确 |
| P1 | Focus Filter | I platform | priority/quiet 状态真实改变通知打断级别，不误关 Widget/Search 等系统表面 |
| P1 | Live Activity 与 Push Token | I platform | 创建/更新/结束、token 注册/注销/重复、隐私和目标事件范围正确 |
| P1 | NSE success/timeout/failure | I/M extension | 内容、附件、fallback 正确 |
| P1 | Widget push/token/snapshot 刷新 | I/W extension/integration | token 生命周期、push handler、revision 前进、重复 push 和 App/Extension 并发一致 |
| P1 | watch snapshot/resync/open target | W integration/UI | 同步正确，过期目标 fallback |
| P0 | Android update candidate/ABI/rollout | D JVM | 版本、渠道、SDK、ABI 选择准确 |
| P0 | Feed 签名/Canonical JSON | D unit/contract | 合法接受，篡改拒绝 |
| P0 Release | 安装权限/下载/校验/安装状态 | D physical | 未知来源拒绝/允许、下载/签名/哈希/PackageInstaller 状态准确；失败不安装，成功版本准确 |
| P1 Release | 安装进程死亡/系统返回/手工 fallback | D physical | 状态 Receiver 可恢复；无重复安装；fallback URI 可读；升级后版本和数据准确 |

### 25.13 watchOS 当前 UI 与独立接收能力

| 级别 | 必测行为 | 层 | 最终 Oracle |
| --- | --- | --- | --- |
| P0 | 冷启动进入 Messages | W UI | 正确 Empty/Content，可通过 Digital Crown 浏览，无永久 Loading |
| P0 | Messages/Events/Things Tab 切换 | W UI | 每个列表显示目标类型独有内容，选择状态正确 |
| P0 | Message 列表字段和详情 | W UI | 标题、时间、severity、正文、图片/链接与独立接收 Store 的 canonical 数据一致 |
| P0 | Message 标记已读 | W UI + Store | 打开准确未读消息后本地立即变为已读，列表未读标识消失且进程重启后保持 |
| P0 | Message 删除/确认取消 | W UI + Store | 取消无变化；确认后本地隐藏，进程重启后仍不存在 |
| P0 | Event 列表/详情 | W UI | 标题、状态、severity、解密状态、更新时间和图片正确 |
| P0 | Thing 列表/详情 | W UI | 名称、状态、关键属性和图片正确 |
| P2 compatibility | 历史镜像状态迁移 | W integration | 仅在产品明确承诺支持旧版本混用时验证；当前手机控制与新安装均强制迁移为 standalone，不进入日常 UI Lane |
| P1 | 通知冷启动打开 Message/Event/Thing | W physical UI | 打开准确目标；缺失目标进入合法 fallback |
| P1 | watchOS 通知内容扩展 | W physical/system UI | 标题、正文、severity、图片/缺图状态与 payload 一致；点击后才按目标路由，不能只验证 HostingController 可实例化 |
| P1 | Receiver Health 正常/等待频道/鉴权失败/恢复 | W UI/contract | 状态、原因和恢复动作与真实 transport 状态一致 |
| P1 | standalone channel sync/失效频道清理 | W contract | 合法频道 active；not-found/password-mismatch 被准确移除并反馈 |
| P1 | provision generation/version/reset | W integration | 旧 generation/version 不覆盖新状态；reset 后全量重建，ACK/NACK 和 pending action 收敛 |
| P1 | 页面可见性与重启 | W UI | Messages/Events/Things 开关真实影响 Tab 并持久化 |
| P1 | Message/Event 图片加载/失败/预览 | W UI | 成功、占位、失败和全屏预览准确；退出后请求和资源释放 |
| P1 | 解密成功/缺 Key/失败 | W UI + sync | 正文或明确状态与手机/standalone 数据一致，不显示垃圾明文 |
| P1 | 10k 列表 reload 与三类详情循环 | W performance | 对象正确、循环完成、内存/stall/时延满足预算 |
| P1 | VoiceOver、Dynamic Type、Digital Crown | W physical/a11y | 打开、阅读、标记已读和删除任务可完成 |

### 25.14 Accessibility、本地化、视觉与性能

| 级别 | 必测行为 | 平台/层 | 最终 Oracle |
| --- | --- | --- | --- |
| P1 | 每个主页面 accessibility audit | I/M/D | 无高严重度描述、命中、对比、裁切问题 |
| P0 | Message/Event/Thing 行语义 | I/M/D | 名称、状态、主要动作可理解 |
| P0 Release | VoiceOver/TalkBack 完成打开、搜索、删除 Undo | physical | 任务真可完成、焦点顺序合理 |
| P1 | 最大动态字体 | I/D UI | 关键按钮和信息可达，无关键裁切 |
| P1 | 键盘导航 | M/D | Sidebar、搜索、详情、Dialog 可完成 |
| P1 | Reduce Motion/高对比/非颜色唯一表达 | I/M/D | 状态仍可理解 |
| P1 | en/zh-CN/zh-TW 主旅程 | I/M/D UI | 文案、布局、搜索、时间格式正确 |
| P0 | 支持语言资源完整性 | A/W/D static contract | 每个生产 key 在支持语言中有非空译文，格式占位符兼容；该合同只防 fallback/格式崩坏，不冒充布局或任务完成 |
| P1 | 代表性中文大字体任务 | I/D UI | 平台与 App 内环境均证明 locale/font 已实际生效；打开准确消息详情并完成一项真实写操作；成功/失败后恢复全局环境 |
| P1 | visual diff | I/M/D | 只提示；变化需人审，不自动更新通过 |
| P1 | 设备/窗口/旋转矩阵 | I/M/W/D UI | 第 33 节代表尺寸下关键任务可完成，无遮挡、越界、不可达或错误重排 |
| P1 | Sheet/Dialog/IME/系统返回 | I/M/D UI | 焦点、键盘、嵌套展示、取消/确认和返回目标正确，不重复提交 |
| P1 | 冷启动 TTID/TTFD | XCTLaunch/Macrobenchmark | 状态/前 50 条正确 + 预算 |
| P1 | 10k 列表滚动 | XCTHitch/FrameTiming | 无丢重错序 + 卡顿预算 |
| P1 | 搜索/详情/筛选 | signpost/trace | 对象/集合正确 + 延迟预算 |
| P1 | 详情往返 20 次 | memory/hitch | 资源回收 + 延迟不持续退化 |
| P1 | ingress 到 UI 可见 | milestones | canonical 字段正确 + 端到端预算 |
| P1 | 100k Store/migration/import | benchmark | count/index/revision 正确 + 预算 |

### 25.15 macOS 窗口、菜单栏与后台任务/服务生命周期

| 级别 | 必测行为 | 平台/层 | 最终 Oracle |
| --- | --- | --- | --- |
| P0 | macOS 状态栏左键打开主窗口 | M physical UI | 复用唯一主窗口，成为 key/main，菜单或 popover 正确关闭 |
| P1 | macOS 状态栏右键菜单 | M physical UI | Open Main Window 和 Quit 可达、文案本地化、动作准确 |
| P0 | 主窗口关闭/最小化/恢复 | M UI/platform | 可见性状态准确；按产品语义继续后台接收；再次打开不重复创建窗口 |
| P1 | 最小窗口和 Sidebar 固定宽度 | M UI | 1100×640 及大窗口下分栏、Toolbar、详情和焦点可用 |
| P0 | 菜单栏未读加载正常/空/失败 | M component/UI | Content/Empty/Error 分开；数据库失败不得被 `try?` 吞成“没有未读” |
| P1 | iOS BGTask 注册/调度/执行 | I integration | permitted identifier、提交、拉取/ACK/derived work 和 completion 结果准确 |
| P1 | iOS BGTask expiration/取消/重启 | I integration | expiration 只完成一次；任务停止；durable work 下次恢复，无重复 ACK/投影 |
| P1 | Android Private Channel Service 启停 | D integration/physical | Transport、前后台、notification、连接状态一致，重复 start 幂等 |
| P1 | Android Boot/MY_PACKAGE_REPLACED 恢复 | D physical | 仅应启用时恢复服务和 Work；禁用态不误启动 |
| P1 | Private Channel 常驻通知划除 | D physical | 服务停止、连接状态和用户反馈一致，可按产品动作恢复 |
| P1 | AlertPlayback Service 状态机 | D integration/physical | 严重级别抢占、timed/continuous、tap/dismiss/read/delete/stop-all 后收敛 |
| P1 | ACK/ingress/post-process/deletion-drain/service-refresh Workers | D device | constraints、retry/backoff、重复调度、进程死亡和最终 exactly-once 语义；删除与服务恢复不能只证明 Worker 被 enqueue |
| P1 | 图片缓存清理 Worker | D device/store | 超限/过期资源按策略删除，仍被引用/正在使用资源不误删，失败可恢复 |
| P1 | Update Check Worker | D device/contract | 开关/周期/网络约束、候选通知、重复运行和进程死亡恢复准确 |

## 26. Fixture/Scenario Catalog 的实现清单

Scenario 是代码工厂，不是人工维护的 JSON 清单。WP1–WP5 必须依次实现：

| Scenario | 内容 | 主要用例 |
| --- | --- | --- |
| `empty.clean` | 新库，无消息/频道/实体 | 启动、空态 |
| `messages.standard` | 12 条，已读/未读、多频道/tag/severity | 列表/筛选/统计 |
| `messages.pagination` | 125 条、稳定时间和 tie id | 分页/排序 |
| `messages.search` | 中英文、大小写、音调、全半角、标点、CJK | 搜索 |
| `messages.markdown` | 表格、列表、链接、代码、引用、任务、长行 | 详情/Markdown |
| `messages.media` | 静态、GIF/APNG、坏 URL、缓存命中/失败 | 媒体/内存 |
| `messages.cleanup_boundaries` | cutoff 前后 1ms、时区/DST、已读/未读、多频道 | 历史清理范围/数量/不误删 |
| `messages.encrypted.valid` | 合法 Key/密文 | 解密成功 |
| `messages.encrypted.missing_key` | 无 Key | 恢复入口 |
| `messages.encrypted.invalid` | 错 Key/坏密文 | 安全失败 |
| `messages.large` | seed + scale=1k/10k/100k | 性能 |
| `events.timeline` | ongoing/closed、patch/tombstone、图片、tags、关联 Thing、timeline ids | Event 搜索/关闭/详情 |
| `events.close_failure` | 可关闭事件 + timeout/HTTP error/重复响应 | 关闭确认/失败/幂等 |
| `things.rich` | attrs/tags/location/external id/metadata、关联 Event/Message/Update、三页签 | Thing |
| `things.deep_link_tabs` | 三个合法 tab + 无效 tab + 已删除对象 | Deep Link/通知路由 |
| `channels.standard` | provider/private、alias、可复制 ID、多状态 | Channel |
| `channels.unsubscribe_keep` | 订阅 + 历史 Message/Event/Thing | 保留历史退订 |
| `channels.pending_delete` | durable operation + Undo | 恢复 |
| `ingress.duplicate` | 多入口同 canonical id | 去重 |
| `ingress.out_of_order` | 旧/新乱序 | 投影 |
| `settings.customized` | 页面开关、server、声音规则/自定义资源、beta、transport | 持久化 |
| `settings.permissions` | 通知 notDetermined/denied/authorized、Doze、声音目录权限 | 系统设置引导/返回刷新 |
| `updates.lifecycle` | Stable/Beta、critical、skip、24h/72h/7d cooldown、安装状态 | Android 更新 UI/Worker |
| `system_surfaces.standard` | unread/critical/object、敏感/解密失败、已删除目标 | Widget/Intent/Spotlight/Live Activity |
| `watch.generations` | full/incremental、旧/新 generation、pending action、ACK/NACK | watch 镜像/重置/恢复 |
| `background.recovery` | durable ingress/ACK/deletion、expiration、process death、boot | BGTask/Worker/Service |
| `migration.vN` | 每个支持旧 schema 最小真实库 | 升级 |

每个 generator 要测试：同 seed 稳定、不同 seed 保持不变量、引用 ID 存在、无真实 token/个人数据、非法 scale 显式拒绝。

## 27. 逐文件实施地图

### 27.1 Apple 新增

```text
Shared/Testing/
├── QualityRuntimeProfile.swift
├── QualitySessionDescriptor.swift
├── QualityScenarioCatalog.swift
├── QualityScenarioGenerator.swift
├── QualityFaultPlan.swift
├── QualityReadiness.swift
└── QualityMilestones.swift

Tests/PushGoAppleTestSupport/
├── QualityAppLauncher.swift
├── QualityUIWaiter.swift
├── QualityUIAssertions.swift
├── QualityScenario.swift
└── QualityFailureAttachment.swift

Tests/PushGo-iOSUITests/Flows/
├── LaunchAndRecoveryUITests.swift
├── MessageListUITests.swift
├── MessageSearchUITests.swift
├── MessageDetailUITests.swift
├── EntityUITests.swift
├── ChannelUITests.swift
├── SettingsUITests.swift
├── MediaPreviewUITests.swift
├── SystemSurfaceUITests.swift
├── BackgroundRecoveryIntegrationTests.swift
├── NotificationRouteUITests.swift
└── AccessibilityUITests.swift

Tests/PushGo-macOSUITests/Flows/（同能力拆分 + `MacWindowAndStatusItemUITests.swift` + Sidebar/Updater/LaunchAtLogin）
Tests/PushGoApplePerformanceTests/{Launch,List,Search,Detail,Ingress}PerformanceTests.swift
TestPlans/Quality-{PR,Nightly,Release}.xctestplan
```

### 27.2 Apple 修改

| 文件 | 改动 |
| --- | --- |
| `Apps/PushGo-iOS/App/AppEnvironment.swift` | Profile/Session Composition Root |
| `Apps/PushGo-macOS/App/AppEnvironment.swift` | 同上 + platform facades |
| `Apps/PushGo-macOS/App/{PushGoAppDelegate,MainWindowLifecycleController}.swift` | Status item、窗口唯一性、关闭/恢复状态和可测试平台边界 |
| `Apps/PushGo-macOS/UI/ViewModels/MenuBarViewModel.swift` | loading/content/empty/error；禁止 `try?` 把 Store 失败吞成空态 |
| `Apps/PushGo-iOS/App/PushGoAppDelegate.swift` | BGTask scheduler facade、expiration/completion milestone |
| `Apps/*/AppContext.swift` | readiness、启动失败、teardown |
| `Shared/Repositories/LocalDataStore.swift` | Store Factory、session URL、open/migration error、revision |
| `Shared/UI/MessageListViewModel.swift` | first/page/refresh state、取消、retry |
| `Shared/UI/MessageSearchViewModel.swift` | query identity、取消、索引状态 |
| `Shared/UI/MessageDetailViewModel.swift` | loading/content/missing/decrypt/media state |
| `Shared/UI/EntityScreens.swift` | Event/Thing state 与 fault boundary |
| `Shared/UI/SettingsViewModel.swift` | saving/failure/effect validation |
| `Apps/*/UI/Screens/*` | 状态渲染、稳定语义、真实结果 |
| `Shared/UI/AutomationRuntime.swift` | 删除任意路径/导航/产品操作，最后退役 |
| `scripts/run_ios_ui_tests.sh` | 动态 simulator、preflight、唯一目录、首错 |

迁移两个 UI 大文件时：先抽 Launcher/Waiter/Assertions；再移动真实点击；再把 seed/count 移到 Store；再把 measure 移到 Performance；新 Oracle 通过后才删旧例。

### 27.3 Android 新增

```text
app/src/main/java/io/ethan/pushgo/testing/
├── RuntimeProfile.kt
├── QualitySessionDescriptor.kt
└── QualityMilestones.kt

app/src/debug/java/io/ethan/pushgo/testing/
├── QualityTestApplication.kt
├── QualityRuntime.kt
├── QualityScenarioCatalog.kt
├── QualityScenarioGenerator.kt
└── QualityFaultInjector.kt

app/src/androidTest/java/io/ethan/pushgo/quality/
├── rules/{QualityAppRule,QualityDeviceStateRule}.kt
├── assertions/{MessageAssertions,EntityAssertions,FailureAttachments}.kt
└── flows/{LaunchAndRecovery,MessageList,MessageSearch,MessageDetail,MediaPreview,Entity,Channel,Settings,UpdateLifecycle,BackgroundRecovery,NotificationRoute,AccessibilityJourney}Test.kt

macrobenchmark/src/main/java/io/ethan/pushgo/benchmark/
├── StartupBenchmark.kt
├── MessageListBenchmark.kt
├── SearchBenchmark.kt
├── DetailBenchmark.kt
└── BaselineProfileGenerator.kt
```

### 27.4 Android 修改

| 文件 | 改动 |
| --- | --- |
| `app/build.gradle.kts` | Orchestrator、Managed Devices、profileableTest、schema export |
| `AppContainer.kt` | Profile/Session 显式组装 |
| `AppAutomationController.kt` | 业务 Use Case 与测试状态解耦 |
| debug `PushGoAutomation.kt` | 删除任意路径/best-effort 写，缩为诊断桥 |
| release `PushGoAutomation.kt` | 不可用并加负测 |
| `PushGoAndroidJUnitRunner.kt` | Test Application、descriptor、首错附件 |
| `MessageList/Search/DetailViewModel.kt` | 完整状态和 milestones |
| `ui/screens/*` | 状态、semantics/testTag、真实操作 |
| `PushGoDatabase.kt` | session DB、migration Fixture |
| `RuntimeComposeUiAutomatorInstrumentedTest.kt` | 按 flow 拆分，移除 state 最终 Oracle |
| `RuntimeDataLayerInstrumentedTest.kt` | 拆 Store 正确性与 benchmark |
| `MainActivity.kt` | fatal Store 与可恢复加载分离；通知/Doze 系统设置返回状态 |
| `notifications/{PrivateChannelForegroundService,AlertPlaybackService,*BootReceiver}.kt` | 可注入时钟/调度/音频/服务边界与生命周期 milestone |
| `update/{UpdateCheckScheduler,UpdateInstallStatusReceiver}.kt` | Worker/Receiver 恢复、安装状态和系统 Intent 边界 |
| `data/ImageCacheCleanupScheduler.kt` | 受控时钟、引用保护和清理结果 |

## 28. 执行命令与 CI Profile

两个仓库统一通过一个可验证入口执行：

```text
scripts/quality_doctor.sh
scripts/quality_test.sh focused
scripts/quality_test.sh pr
scripts/quality_test.sh nightly
scripts/quality_test.sh accessibility
scripts/quality_test.sh performance
scripts/quality_test.sh release
```

`doctor` 只检查工具链、设备、可安装性、磁盘、账号变量和目标构建，不能给产品打 `PASSED`。

| Profile | 必须执行 | 目标反馈 |
| --- | --- | --- |
| Focused | 受影响 compile + Pure/VM/Store + 最多一条核心 UI | 约 3 分钟 |
| PR | 快速 Core/JVM/Store 合同 + 每端低成本跨域正向核心 + 历史高风险纵切 + 影响分析追加的 owner-focused；Apple 固定 iOS UI 为 4 条，不默认执行故障注入、系统表面或全 Settings | 约 5–15 分钟，按平台并行校准 |
| Nightly | 先完成 iOS/macOS/watch/Android 的完整高价值正向集合，再运行 fault/migration/a11y/后台与系统表面 contract；正向失败即停止后续风险批次 | 约 60–120 分钟 |
| Accessibility | 支持语言资源完整性 + 一个实际中文最大/大字体核心任务；复核产品实际 locale/font，并恢复平台设置；物理 VoiceOver/TalkBack 另报 | 约 1–3 分钟，按需和 Nightly/Release 执行 |
| Performance | 每周或性能敏感变更显式触发；100k 生产 Store/Room correctness + provisional host/emulator ceiling，独立保存指标；不进入普通 PR | 当前约 3 分钟产品执行，随固定参考设备补充而校准 |
| Release | 最新有效 Nightly P0 证据 + Nightly 必要集 + Release-like 性能 + 第 33 节代表物理设备/窗口 + real APNs/FCM/private + Widget/Intent/通知动作 + 升级安装 | 约 120–180 分钟，按设备池校准 |

watchOS 的 P0 UI 至少进入 Nightly；若变更直接触及 watch 共享模型、同步、路由或 UI，则通过影响分析提升到 PR。任何 P0 只要最近一次应执行结果为 `FAILED/FLAKY/BLOCKED/NOT RUN`，Release 汇总不得显示为通过；证据有效期由构建身份和相关路径变化共同决定，不能沿用不相干的旧绿色。

路径映射只是最低执行，不是完整影响分析：

| 修改范围 | 最低检查 |
| --- | --- |
| Parser/Decryptor | unit/property + ingress integration |
| Message List VM | state + Store query + 1 list UI |
| List UI | 正常 + slow/error + accessibility semantics |
| schema/migration | old→new + reopen + UI smoke |
| Runtime/Runner | Runtime self-test + UI smoke + Release isolation |
| notification/route | synthetic production chain + device route as required |
| Widget/Intent/Spotlight/Focus/Live Activity | 对应 summary/router/privacy contract + 至少一条真实系统入口 |
| Android Service/Worker/Receiver | 状态/策略 unit + process-death/reboot device cell |
| macOS window/status item | component state + physical UI open/close/reopen |
| 图片/媒体 | parser/cache component + preview/save/share UI + lifecycle performance |
| performance-sensitive Store | correctness + benchmark dry run |

结果必须使用六态：`PASSED/FAILED/FLAKY/BLOCKED/NOT RUN/WAIVED`，并同时报告 `product_capability_status` 和 `test_system_status`。

## 29. 实施工作包与退出条件

逐项初步工作量合计 102–147 人日；新增工作主要来自此前遗漏的 Channel 双终点、Event close、Thing 真实页签、媒体预览、系统表面和后台生命周期。WP2 后按真实速度重新估算，不是交付承诺；不得为了维持旧估算再次合并用户目的不同的用例。

### WP0：去伪审计与基线（4–6 人日）

1. 建立现有测试到能力/Oracle/Runner 的临时清单；
2. 找出 existence/state/version-only、静默 return/skip、retry、宽 timeout；
3. 对全部 P0 assertion path 做 review；
4. 运行最小现有 smoke，记录首错、启动成功率、flake、耗时；
5. 对“有实现文件但无调用入口”的候选做可达性裁决，当前至少包括三端导出 helper 和 `MacMenuBarContentView.swift`；
6. 完成 `keep/rewrite/move/delete/diagnostic` 处置。

退出：每个 UI/device 测试都有处置决定，没有“数量多所以保留”。

### WP1：Runtime 和环境闭环（10–15 人日）

1. 两端 Profile/Descriptor/Composition Root；
2. App-owned session Store；
3. `empty.clean/messages.standard/messages.large`；
4. readiness、doctor、teardown；
5. Apple 去 absolute path；Android target Context + Orchestrator；
6. Release isolation；
7. 连续 50 次启动并归因每次失败。

退出：无需人工权限/复制 DB；准备失败 10 秒内明确；Release 无 Runtime。

### WP2：慢加载纵向样板（10–14 人日）

1. Message List first/page/refresh state；
2. first-page delay/query failure；
3. VM 状态序列；
4. 10k Store correctness/performance；
5. UI 正常、2 秒慢、超预算、失败 Retry、旧内容 Refresh；
6. first meaningful content milestone；
7. 用户预算和参考设备；
8. 超预算 delay 负控；
9. 红方/蓝方/归因审计；
10. 接入 Focused/PR。

退出：能稳定抓住慢加载；Store/VM/UI 延迟可归因；两端语义一致；不读 state/path 判成功。

### WP3：Messages 全能力（16–22 人日）

按列表/分页→筛选/刷新→搜索→详情→Markdown/media/decrypt→全屏预览/保存/分享→六档历史清理→删除迁移。退出：第 25.3–25.5 的 P0/P1 落地，保存/分享失败不假成功，旧 state Oracle 退役，10k Nightly 通过。

### WP4：Events/Things/Channels/Settings（22–32 人日）

完成 Event close/只看未关闭、Thing 三真实页签及关联对象、Channel copy/rename/两种退订终点、声音编辑器、权限/Transport/Doze/更新 UI，以及第 25.13 的 watch UI 基础能力。退出：每个入口的确认/取消/成功/失败/重启终点均有证据，远端错误和进程死亡不造成错误成功态。

### WP5：Ingress/通知/系统表面/真实系统（22–30 人日）

完成 TestIngress 生产链、物理设备账号、APNs/FCM/private、通知动作/划除/声音、Apple Widgets/Controls/Intent/Shortcut/Spotlight/Focus/Live Activity、iOS BGTask、Android Service/Worker/Boot/Update、macOS Window/Status Item、第 25.13 的 watch 同步/Receiver/Complication。退出：P0 Release real-system 无 `NOT RUN`；P1 系统项有执行证据或明确 owner/deadline。

### WP6：性能/可访问性/本地化（10–16 人日）

落地 XCTMetric、Macrobenchmark、预算校准、物理设备、a11y 任务矩阵、多语言。退出：性能负控有效，候选满足预算，关键辅助任务可完成。

### WP7：CI/AI/治理收口（8–12 人日）

五个脚本、CI、精简 AGENTS、PR 模板、轻量能力覆盖索引、flake owner、历史 AI 任务评估、删除旧 Runtime/重复脚本。退出：连续两周稳定运行；第 32 节双向检查没有未解释缺口。

每个 WP 独立可回滚；新旧 Runtime 最多并存一个里程碑；旧用例只有在新用例 Oracle 更强或等价且通过后才删除。

## 30. 红蓝审计、归因分析与负控复核

### 30.1 红方：如何让坏功能变绿

| 攻击 | 防线 | 结论 |
| --- | --- | --- |
| 只断言 screen/identifier 存在 | 必须断言内容、对象、动作、durable result | 已阻断 |
| 用 Automation State count | state 只诊断 | 已阻断 |
| Fixture 文件存在即通过 | App-owned seed + UI 消费 | 已阻断 |
| artifact 不可用直接 return | Hermetic fail，Suite 级显式 block | 已阻断 |
| 扩大 timeout | 用户预算 + milestone + delay 负控 | 已阻断 |
| 重试取一次绿 | 保留 FLAKY，只允许一次 transient retry | 已阻断 |
| 直接 DB 插入声称 FCM | TestIngress/real-system 分开 | 已阻断 |
| Runtime 直接导航 | 仅截图允许；回归真实操作 | 已阻断 |
| 性能返回空数据更快 | correctness guard | 已阻断 |
| 自动更新 Snapshot | 变化需人审 | 已阻断 |
| Release 携带后门 | 编译/source-set 隔离 + 负测 | 已阻断 |
| BLOCKED 合并绿色 | 六态 + P0 Release 无 NOT RUN | 已阻断 |
| 路径没命中所以少跑 | caller/consumer impact 补充 | 已阻断 |
| 全改 E2E 造成团队绕过 | 风险分层 + 少量关键 Journey | 已修正 |
| 用复杂 Manifest 制造形式负担 | Scenario code + 最小标签 | 已修正 |
| AI 删除断言/加 skip | diff 检查 + Oracle challenge | 已阻断 |
| 用一个“Entity Tabs”用例代表不存在的页签 | 源码可达 UI 反向核对 + Events/Messages/Updates 分项 | 已修正 |
| 把两种 Channel 退订都断言“行消失” | 分别验证保留历史与删除历史的数据终点 | 已修正 |
| 导出 helper/文档类型存在就宣称用户可以导出 | 先追真实入口和调用链；无入口时只允许接通或删除，不允许 UI 测试直接调 helper 冒充任务 | 已修正 |
| Event 底层投影测试代表用户能关闭事件 | 真实点击确认/取消/失败 + 列表/Thing 关联收敛 | 已修正 |
| 图片显示成功代表预览/保存/分享可用 | 文件消费者、MIME、失败态和生命周期 Oracle | 已修正 |
| Widget/Intent 任选一个通过代表全部系统表面 | 按用户目的拆 Widget/Control/Intent/Spotlight/Focus/Live Activity | 已修正 |
| Store 错误吞成 Empty | 每个次级表面显式 Loading/Content/Empty/Error + failure fault | 已修正 |
| Service/Worker 类存在或被调度就算成功 | process death/reboot/重复调度/最终数据和用户状态 | 已修正 |
| 截图在标准尺寸好看就代表 UI 正确 | 第 33 节代表尺寸 + 关键任务可完成，截图只提示 | 已修正 |

### 30.2 蓝方：能否融入现有工程

| 问题 | 最终选择 |
| --- | --- |
| 是否统一 Runner | 不；只统一能力/scenario/结果语义 |
| 是否重写几百个测试 | 不；保留强低层测试，渐进迁移弱 UI/Runtime |
| Runtime 是否第二套 App | 不；只替换 Composition Root 边界 |
| Scenario 是否巨大系统 | 不；小型 generator + seed/scale |
| 每 PR 是否全平台全量 | 不；Focused/PR/Nightly/Release |
| 是否统一硬阈值 | 不；统一用户语义，平台/设备校准 |
| AI 是否每次读全文 | 不；AGENTS + scripts 热路径，按章节检索本文 |
| 是否创建总覆盖分 | 不；逐能力状态，不合并成分数 |
| 是否立即删旧 Runtime | 不；一个里程碑兼容，先脱钩再删 |

### 30.3 数据未显示故障树

```text
未显示
├── 测试未开始：install/launch/session/store/seed
├── 入口未产 canonical：parse/decrypt/route/dedupe
├── 未持久化：open/migration/transaction/sandbox
├── Repository 未发布：query/filter/observer/index
├── ViewModel 错：未请求/错误取消/旧覆盖新/错误吞成 loading
├── UI 错：未渲染/identity/selector/布局
└── 性能超预算：query/decode/main-thread/image/network
```

区分顺序：launch exit→最后启动 milestone→canonical id→Repository 同 filter 查询→VM 状态序列→语义树/截图→Store/VM/UI signpost。归因以最早偏离点为准，不以日志最后一行或重试结果猜测。

### 30.4 Oracle 负控

| Oracle | 负控 | 必须发生 |
| --- | --- | --- |
| 列表字段 | 故意错配期望 id/title | UI 指出具体字段失败 |
| 分页 | fake 返回重复 cursor | VM/组件失败 |
| 搜索 | 旧 query 晚返回 | 状态机拒绝旧结果 |
| 持久化 | success 前 commit 失败 | UI 不显示最终成功，relaunch 不保留 |
| 去重 | 两入口同 canonical id | 重复消息/通知会被抓住 |
| 性能 | delay 超预算 | 测试失败，不能继续等 |
| 可访问性 | 测试组件移除关键 label | audit/semantics 失败 |
| Release isolation | descriptor 启动 Release | Runtime 不激活 |
| real-system | 凭据不可用 | `BLOCKED`，不得 synthetic PASSED |
| Thing 页签 | 让 Events 内容为空、Messages 内容串到 Updates | 页签集合/对象/空态/返回位置断言失败 |
| Channel 保留历史 | 误删历史或继续接收新消息 | 重启后历史/路由终点对账失败 |
| Event close | API 成功但本地仍 ongoing，或失败却显示 closed | contract + projection + UI 三方对账失败 |
| Store 错误态 | fault 返回 open/query error | 不能落入 Empty/永久 Loading，必须走正确 fatal 或 Retry 状态 |
| 图片保存/分享 | 目标 URI 不可读或写入中断 | 不得显示成功，消费者读取检查失败 |
| 系统表面隐私 | 注入 decryptFailed/敏感 metadata | Widget/Spotlight/Intent 输出不得泄露受保护正文 |
| 后台恢复 | completion 前 kill/reboot/重复 schedule | durable work 最终一次收敛，重复/丢失会失败 |

每季度和基础设施重大改造后重跑负控；负控不红时，对应 Suite 的绿色证据失效。

### 30.5 审查限制

本次红方、蓝方和归因分析由同一上下文执行，只能称为同一上下文审查，保留 `common-mode-risk`。WP1、WP2 和最终关键 Diff 必须由未预读实现结论的 reviewer 独立检查 Release 隔离、migration、真实推送、性能 Oracle、skip/retry。

## 31. 日常 AI 闭环与前十个工作日

### 31.1 AI 每次修改必须执行

```text
读规则和相关代码/测试
-> changed symbol 到 callers/state/data/platform consumers
-> 写一句用户结果和保护行为
-> 选择最低可靠层 + 必要 UI/平台层
-> 先补可失败测试（可行时）
-> 改生产代码
-> focused
-> 首错归因，不盲重跑
-> 受影响 suite/PR
-> 检查 skip/timeout/弱断言/后门
-> 报告六态与未运行项
```

新 UI 状态必须有正常和 error/recovery；新持久字段必须 migration/reopen；新入口必须成功/错误/超时/幂等；新后台任务必须取消/死亡/恢复/重复；性能查询必须 correctness + benchmark。AI 无权 commit、push、发布、跳过或豁免。

CI 只对高价值反模式做复核提醒：新增 skip/ignore、固定 sleep/timeout 大增、空 catch/`try?`/`runCatching`、UI 最终只断言 state/file、Runtime 新增 path/sql/navigation、删除断言/扩大视觉 tolerance、性能移除 correctness、Release 出现 Runtime。

每月用至少 10 个历史真实任务评估 AI；一次只改变 Prompt/AGENTS、上下文、脚本、环境或模型中的一个因素，不输出伪精确总分。

### 31.2 前十个工作日

| 天 | 任务 | 当日可验证产物 |
| --- | --- | --- |
| 1–2 | WP0 测试清点、处置、现有 smoke 首错 | 两仓库 disposition + P0 缺口 |
| 3–4 | 两端 Profile/Descriptor/Composition Root/Release 负测 | `empty.clean` App-owned store 启动 |
| 5–6 | `messages.standard`、readiness、doctor、teardown | iOS/Android 首屏真实 UI 连跑 20 次 |
| 7–8 | Message List 状态、delay/failure、VM tests | Loading→content、error→retry→content |
| 9–10 | milestone、性能负控、红蓝/归因审计、PR 观察 | 能稳定抓住慢加载的两端纵向样板 |

第十天的退出条件不是“框架代码写完”，而是：不需要复制数据库或处理路径权限；慢加载能被抓住；数据字段正确；失败能定位到 Store/VM/UI；Runtime 不能自证产品成功。只有这条样板通过后，才按 WP3–WP7 扩展全部功能。

## 32. 覆盖闭环：防遗漏，但不把索引当测试

### 32.1 轻量能力覆盖索引

两个 App 仓库分别维护 `docs/quality/capability-coverage.md`。它只回答“哪些真实用户能力需要哪些证据”，不生成总覆盖分，不因为文件、类、Identifier 或测试名存在而通过。每行只保留：

| 字段 | 内容 | 禁止替代 |
| --- | --- | --- |
| 平台/真实入口 | 用户能够到达的 Screen、通知、Widget、Intent、系统设置或后台触发 | 源文件存在 |
| 用户目的 | 用户最终要完成什么 | 按钮存在 |
| 关键状态/分支 | 正常、空、慢、错误、取消、恢复、重复、进程死亡中适用者 | “happy path 已测” |
| 数据/系统终点 | Store、远端、剪贴板、文件、通知、Worker、Widget 等可观察终点 | Automation state/count |
| 最低证据 | unit/component/store/UI/physical 中能证明目的的最小组合 | 全部堆成 E2E |
| Lane/状态 | Focused/PR/Nightly/Release 与六态结果 | 一个绿色总分 |
| 源码 owner | 入口、Use Case/VM、Store/Service 的主要 owner 路径 | 永久测试编号 |

维护方式：`scripts/quality/audit-capabilities.sh` 只从导航、可见 Action、App Intent/Widget 声明、Manifest/Delegate 后台组件和现有测试中生成“候选差异”；人或 AI 必须阅读可达性和用户目的后合并。脚本发现新符号只能提示缺口，不能证明它是功能，也不能自动创建无意义测试。

### 32.2 双向检查

每个 PR、Nightly 和每次功能清点都做两次方向相反的检查：

1. **源码→测试**：新增或改变的用户入口、动作、状态、持久数据终点、系统表面或后台组件，是否在索引中有用户目的和最低证据；
2. **测试→产品**：测试描述的页面、页签、动作和状态在当前产品中是否真实可达，是否仍符合产品语义。

未匹配项只能是：补测试、修正文档/测试、确认死代码并删除、或带 owner/deadline 的明确延期。`rg` 未发现、路径规则未命中、测试数量很多、低层测试很强，都不是“覆盖完成”的理由。

这次反向检查已经发现并修正一个真实反例：原 Thing 条目写成 `Summary/attrs/updates/messages`，而当前三端真实 Tabs 是 `Events/Messages/Updates`；概览、attrs/metadata 不是 Tab。以后同类不一致必须在编码前失败，而不是 UI 测试实现后再发现。

### 32.3 状态转换最小表

状态表按用户目的维护在测试代码/fixture 旁，不建立大型中央状态机。所有有状态能力至少覆盖下面适用边：

| 能力 | 必须允许 | 必须拒绝/保持 |
| --- | --- | --- |
| 首次加载 | idle→loading→content/empty/error；error→retry→loading | error→empty、旧请求覆盖新结果、永久 loading |
| 分页/刷新 | content→paging/refreshing→content；失败保留旧内容 | 清空旧内容、重复 cursor、并发重复追加 |
| Event close | ongoing→closing→closed；closing→error→ongoing | closed 再显示动作、失败却显示 closed、重复 timeline |
| Channel rename | current→saving→renamed；saving→error→current | 空白提交、失败覆盖旧名 |
| Channel keep-history unsubscribe | subscribed→unsubscribing→unsubscribed+history | 误删历史、继续接收新消息 |
| Channel delete-history unsubscribe | subscribed→pending-delete→undo/submitted→deleted | Undo 期远端删除、历史复活、与 keep-history 并发 |
| 图片预览 | thumbnail→loading→preview/error→dismissed | 保存失败显示成功、退出后动画/下载继续 |
| 更新提示 | candidate→install/later/skip；install→permission/download/verify/install/result | 被跳过版本反复提示、失败包继续安装 |
| 后台工作 | scheduled→running→completed/retry/expired；reopen/reboot→resume | completion 两次、丢 durable work、重复副作用 |
| watch 同步 | full/incremental generation→applied→ACK；NACK/reset→full | 旧 generation 覆盖新状态、ACK 前删除 action |

新能力如果不适合此表，仍要用同等强度的输入—动作—可观察终点描述。状态名本身不是 Oracle。

### 32.4 数据血缘与对账点

数据正确性按以下血缘验证，不只在 UI 最后一跳抽样：

```text
APNs/FCM/Private/TestIngress
-> parse/decrypt/canonical identity
-> durable ingress/ACK journal
-> Message/Event/Thing canonical Store
-> search index/stats/projection/revision
-> ViewModel page/detail state
-> App UI / notification / Widget / Intent / Spotlight / Watch
-> read/close/rename/delete/unsubscribe
-> local/remote/system-surface reconciliation
```

代表记录必须能用同一 canonical id/correlation id 追踪；正文和 token 不进入普通日志。每个变换点保留“数量、身份、关键字段、revision、删除状态”中最小必要对账。删除/退订必须反向检查所有 sink：主表、投影、搜索、统计、通知、图片缓存、Widget snapshot、Spotlight、Watch pending action 和远端订阅。

### 32.5 当前可达能力基线

WP0 必须至少把以下当前源码事实写入覆盖索引，不能被更粗的“Entity/Settings/System”行替代：

| 表面 | 当前必须拆开的能力 |
| --- | --- |
| Messages | 列表/分页/搜索/筛选/刷新/mark one/all read/删除 Undo/六档历史清理/详情/解密/Markdown/图片预览保存分享 |
| Events | 列表/搜索/Channel/Tag/只看未关闭/详情 timeline/关闭/删除/Thing 内关联事件 |
| Things | 列表/搜索/只看 Active/Channel/Tag/概览/Events-Messages-Updates Tabs/metadata/关联对象/指定 Tab 路由/删除 |
| Channels | 创建/订阅/复制 ID/rename/keep-history unsubscribe/delete-history unsubscribe/Undo/provider-private |
| Settings | Gateway/token/page visibility/decryption/声音编辑/通知权限/docs/version/iOS Watch/macOS login-update/Android transport-Doze-update |
| Apple 系统 | 3 类 Widget、watch complication、5 个 Control Widget、当前 App Intents/10 Shortcuts、Spotlight/User Activity、Focus、Live Activity、NSE、Widget push |
| watchOS | 三列表/三详情/read/delete/image/decrypt/standalone provisioning generations/Receiver Health/notification route/complication；历史 mirror 仅在兼容承诺存在时测试 |
| macOS | Sidebar/split/detail/Updater/Launch at Login/Window close-reopen/Status Item/菜单栏数据错误态 |
| Android 后台 | FCM、Private foreground service、Boot/Dismiss Receiver、AlertPlayback、ACK/Ingress/PostProcess/Deletion/ImageCleanup/Update Workers、Install Receiver |

当前三端均能检索到导出序列化/helper 实现，但本轮未检索到明确的用户入口调用；WP0 必须决定接通还是删除，接通前不能把第 25.12 节的 Picker/分享任务记为现有能力通过。`MacMenuBarContentView.swift` 当前也未发现真实挂载入口：在确认挂载前只列为死代码候选，不得用“文件存在”声称菜单栏消息列表已实现。`pushgo-windows` 不在本文范围；若目标改为全部 App 平台，必须另行纳入而不能默认为已覆盖。

### 32.6 新代码的强制增量规则

以下变化必须与代码在同一 PR 更新索引和测试：

- 新 Screen/Route/Tab/Sheet/Dialog/可见 Action：正常目的 + 关键 error/recovery；
- 新持久字段/索引/统计：写入、读取、migration/reopen、删除/重建；
- 新 Widget/Intent/Shortcut/Notification action：输入、目标缺失、隐私、最终路由/副作用；
- 新 Service/Worker/Receiver/BGTask：取消、重复、进程死亡、系统重启或 expiration；
- 新系统权限/设置跳转：拒绝、允许、返回刷新、不可用 fallback；
- 新性能敏感查询/媒体路径：correctness guard + benchmark + 资源释放；
- 修改用户语义但只改已有测试期望：必须用负控或评审证明不是顺着实现改答案。

CI 对“新增入口但索引未更新”只做阻断式提醒；最终是否需要新增测试由影响分析决定。禁止为了消除提醒而添加只断言类名、版本、文件或 Identifier 的空壳测试。

## 33. 代表环境、性能门槛与方案自验证

### 33.1 设备、窗口和 UI 状态矩阵

不做全笛卡尔积。PR 跑主环境，Nightly 跑边界环境，Release 跑物理代表环境：

| 平台 | PR 主环境 | Nightly 边界 | Release 物理/系统 |
| --- | --- | --- | --- |
| iOS | 当前 Xcode 默认 iPhone、当前 iOS、portrait | 最小支持 iOS 17 + 小屏 iPhone、当前 iOS + 标准屏；浅/深色、最大字体 | 一台最老支持档和一台当前档；真实权限、通知、Widget/Control/Intent/Live Activity |
| macOS | 当前 macOS、1100×640 | 1100×640/大窗口、浅/深色、键盘/VoiceOver、关闭/恢复 | 当前支持的 Intel/Apple Silicon 兼容方向按发布矩阵；Status Item、Login Item、Updater、通知 |
| watchOS | 当前 simulator 标准尺寸 | 当前支持最小/最大表径、Digital Crown、最大字体 | 配对 Watch：镜像/standalone、通知、complication、Receiver Health |
| Android | main API、标准 phone portrait | min/main/latest API；compact/大屏、portrait/landscape、fontScale、dark、back gesture/IME | 一台最低性能档和一台当前档；通知/Doze/Private Service/reboot/安装权限/升级 |

每个主页面至少覆盖 Empty、Loading、Content、Error；有缓存或刷新者再覆盖 Stale/Refreshing，有局部失败者覆盖 Partial。Dialog/Sheet 必须覆盖确认、取消、系统返回、键盘遮挡和重复点击。视觉差异不自动判功能失败，但关键文本不可读、动作不可达、对象错配和辅助任务无法完成必须失败。

具体型号在 WP2 预算校准前写入 `docs/quality/reference-devices.md`；必须是 CI/设备池真实可用型号，不能在文档中虚构。更换型号时保留档位、OS、刷新率、CPU/内存和基线可比性。

### 33.2 初始性能 SLO

下面是首轮用户体验目标，不是从当前慢基线外推的宽阈值。WP2 在 Release-like 构建和真实参考设备上采集两周方差；若噪声使门禁不可执行，先修测量/设备稳定性，产品目标变化需给出用户影响证据。业务区间使用 p95；Android 启动按 `StartupTimingMetric` 原生结果以 median 为主要比较值并同时限制 max，避免把平台不直接提供的 p95 伪装成原生指标。

| 旅程 | 初始硬目标（参考设备） | 正确性守护 |
| --- | --- | --- |
| 冷启动到可操作 Empty/Content | 10 次 measured：median ≤ 2.0s、max ≤ 2.5s | 初始状态、前 50 条、导航可用 |
| 暖启动/恢复到可操作 | 10 次 measured：median ≤ 0.9s、max ≤ 1.2s | 原选择、页签、未读和刷新状态正确 |
| 10k 首屏 Store query→UI content | ≤ 800ms | 前 50 条 id/字段/顺序准确 |
| 下一页/Refresh | ≤ 800ms（受控本地数据） | 旧内容保留、只追加/替换一次 |
| 10k 搜索/筛选 | ≤ 1.0s | 目标集合和排除集合准确 |
| 详情打开（不等远端原图） | ≤ 700ms | id、正文、metadata、已读副作用准确；图片占位 ≤ 300ms |
| 设备已收到 payload→UI 可见 | ≤ 1.5s | canonical id、Store、通知、列表一致；公网传输另报 |
| 列表交互 | 无 >700ms frozen frame；slow-frame 比例 <5% | 无丢失/重复/错序，滚动后仍可操作 |
| 详情往返 20 次 | p95 不比前 5 次恶化 >20%；退出后媒体/任务归零 | 对象始终正确，无持续下载/播放 |
| 100k migration/reopen | 在平台校准预算内且无超 2× 基线回归 | count/index/revision/页面可用 |

真实 APNs/FCM 公网端到端受外部网络影响：Release 记录分段时延，硬门禁使用“设备收到→持久化→UI”区间；Provider→device 以服务 SLO 独立判定，不能用扩大 App timeout 掩盖。

任何性能阈值变更都必须同时保留：工作负载、数据分布、设备/OS、构建、冷暖、样本/方差、旧/新目标、用户影响理由和 delay 负控。绿色但数据显示错误时性能结果无效。

### 33.3 本方案的多视角验证结果

| 验证视角 | 实际检查 | 本轮修正/结论 |
| --- | --- | --- |
| 黑盒用户目的 | 从每个可见入口追到用户结果 | 增加 Event close、Thing 三 Tabs、Channel copy/rename/双退订、媒体保存分享、权限/更新动作 |
| 白盒分支 | Screen、VM/Use Case、Store、Manifest/Delegate、Extensions、Worker/Receiver | 增加 BGTask、Service/Boot/Dismiss/Alert、Update/Image Workers、macOS Window/Status Item |
| 数据血缘 | ingress→Store→projection/index→UI/system→mutation/delete | 增加各 sink 对账，区分 keep-history 与 delete-history 终点 |
| 有限状态表 | slow/error/cancel/retry/duplicate/death/reboot | 第 32.3 节明确允许边和禁止边，不让状态名替代结果 |
| Oracle 反例 | 错字段、重复 cursor、错误吞 Empty、保存假成功、敏感系统输出 | 第 30.4 节新增负控；对应负控不红则 Suite 绿色失效 |
| 红方 | 尝试用存在性、聚合条目、单系统表面、标准截图、Worker 调度变绿 | 第 30.1 节逐项阻断；Capability 索引明确不计分、不判通过 |
| 蓝方可实施性 | 复用现有 XCTest/Swift Testing/Compose/UIAutomator/Room/Worker/Widget/Intent 测试资产 | 不更换主测试框架；扩展工作量调整为 102–147 人日并按 WP 分段退出 |
| 双向覆盖 | 源码→测试、测试→可达产品 | 修正 Thing 错误规格和 Android 行动作过度声称；标记导出候选、未挂载 MacMenuBarContentView 和范围外 Windows |
| 环境可执行性 | App-owned Store、readiness、doctor、teardown、Release isolation | 保留无需复制 DB/处理跨沙箱权限的核心设计；准备失败 10 秒内分离 |
| 非功能 | 设备/窗口、a11y、视觉、性能/资源 | 新增第 33.1 矩阵和第 33.2 初始 SLO |

### 33.4 完整性复核清单

方案再次定稿前必须逐项回答，并把证据放在覆盖索引、测试代码或 CI 结果中，而不是在评审会上口头确认：

1. 每个当前可达页面、Tab、Sheet、Dialog、通知动作、Widget/Intent 和系统设置入口是否有用户目的；
2. 每个用户目的是否验证准确对象/集合/字段，而不是只验证入口存在；
3. 每个写操作是否覆盖取消、失败、重复和重启后的真实终点；
4. 每个加载页面是否区分 Empty、Loading、Content、Error，失败是否可能被吞掉；
5. 每个后台能力是否覆盖取消、expiration/process death/reboot/重复调度中适用者；
6. 每个持久/删除动作是否对账全部派生 sink 和远端副作用；
7. 每个系统表面是否覆盖目标缺失、隐私和从系统返回 App 的路由；
8. 每个 P0/P1 是否放在会真实执行它的 Lane，并且 `BLOCKED/NOT RUN` 不被绿色汇总隐藏；
9. 每项性能结论是否带正确性、参考环境、样本/方差和能使它失败的负控；
10. 是否存在测试描述的功能在产品不可达，或产品能力没有测试责任；
11. AI 是否能从变更符号追到 caller/data/platform consumers，而不是只按路径模板少跑测试；
12. Release 是否完全不能激活 Runtime，测试失败是否仍能在 10 秒准备阶段或首个业务 milestone 准确归因。

以上任何一项无法回答时，覆盖状态不是 `PASSED`。方案文档层面的源码反向核对、Oracle 设计和同一上下文红蓝审查已经完成；真实测试实现、CI 连跑、物理设备、系统权限、真实推送、性能样本和独立 reviewer 证据均仍为 `NOT RUN`，不得把“设计已完整”描述成“产品质量已证明”。本轮评审不是独立上下文，保留 `common-mode-risk`。
