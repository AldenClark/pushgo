# PushGo 全栈质量体系实施进度

## 状态

**体系改造进行中，不能宣称完成。** 当前已完成 Runtime/环境底座和 Messages 的首个高价值纵向样板，但设计第 21.2 节的完成条件尚未满足。WP3–WP6 仍有大量当前产品可达能力未迁移，不只是需要真机/外部系统的发布证据。低价值边缘组合不进入日常门禁，但这不能用于延期高频 P0 功能。

## 工作包真实状态（2026-08-28 重新核账）

| 工作包 | 状态 | 已证明 | 尚未完成、不能被现有绿色替代 |
| --- | --- | --- | --- |
| WP0 去伪审计 | `VERIFIED` | 两仓库现有 UI/device 测试均有 disposition，弱 Oracle、路径协议、skip/return 和死代码候选已形成基线 | rewrite/move/delete 的实际迁移属于 WP3–WP7，不因 WP0 退出而视为完成 |
| WP1 Runtime/环境 | `PARTIAL` | 两端 App-owned session Store、确定 fixture、readiness、doctor、teardown、Release 隔离 | 50 次启动 ≥98% 尚未执行；Apple/macOS 与 Android 遗留 Runtime 仍保留绝对路径/内部 state 协议；准备失败 10 秒内的全套证明不完整 |
| WP2 慢加载样板 | `PARTIAL` | Messages 首次加载 slow/error/retry 的真实 UI 状态与内容终点已证明 | 分页/refresh 的旧内容保留、里程碑、真实参考设备预算、超预算性能负控未完成 |
| WP3 Messages | `PARTIAL` | 空态、标准字段/详情/relaunch、搜索代表例、删除 Undo、首次慢/错恢复 | 分页、筛选、refresh、mark read/all、删除不撤销、历史清理、Markdown/media/decrypt 以及 10k UI/性能未完成 |
| WP4 Entity/Channel/Settings/watch UI | `PARTIAL` | Apple/Android Event/Thing App-owned 摄入→投影→准确详情；Android Thing 三个真实关系页签；两端真实主导航；部分低层合同 | Event close/筛选；Thing 关联打开/深链；Channel create/rename/双退订；Settings 持久化/解密/可见性/transport；watch P0 UI 未完成 |
| WP5 Ingress/系统能力 | `PARTIAL` | 两端 ACK/去重/迁移等低层证据较强 | 当前可模拟的通知路由、后台恢复、macOS Window/Status Item、Apple 系统表面仍缺；真实 APNs/FCM/private/权限/安装需外部环境 |
| WP6 性能/a11y/l10n | `NOT STARTED/PARTIAL ASSETS` | Android 部分 semantics、两端慢状态可证伪 | Macrobenchmark/Baseline Profile、Apple XCTMetric、参考设备/SLO 样本、物理辅助任务、多语言/尺寸矩阵未完成 |
| WP7 CI/AI/治理 | `PARTIAL` | lane wrapper、CI、AGENTS/AI policy 已建立；本轮增加双状态结构化结果并让 Android PR 执行核心 App UI | 变更影响选测、能力候选审计、flake owner、两周观察、历史 AI 任务评估、旧 Runtime 退役尚未完成 |

## 已交付

- Apple 设计基线 `2becfd8`、首轮实现 `af69dd1` 与 Android 首轮实现 `7096e43` 已提交；本轮搜索/删除/导航、边测边修和 lane 剪枝保持为独立后续提交，便于审阅与回滚。
- 两仓库均有类型化 Quality Session、唯一 App-owned Store/数据库、内置确定性 fixture、readiness、doctor、teardown 和 Release 隔离。
- Apple 已有 `empty.clean`、`messages.standard`、`messages.large`、`event.standard`、`thing.standard`；Android 已有前三项。Fixture 不再依赖 Runner 读取宿主数据库或把宿主 DB 路径交给 App。
- 消息列表已把首次加载、慢加载、错误、Retry 和真实数据终点建模为产品状态；一次故障保持到用户 Retry，避免自动消耗造成假绿。
- Apple iOS 与 Android 均新增 App-owned 纵向旅程：空态、准确列表字段、详情、重启、慢加载可见、失败可见、Retry 后真实恢复。
- Apple 事件/事物 fixture 走真实消息摄入与投影，不以“实体文件/行存在”代替详情可打开；用例从真实 Tab 和列表行进入。
- Apple Runner 串行执行、先 build-for-testing、再 test-without-building；只对已知 Runner 启动故障重试一次，业务断言不重试；禁用失败后的长时自动诊断采集。
- Android Runner 在 Application 创建前配置会话，结束时释放 Room、删除唯一 DB 和 session artifacts；日常 device lane 只跑核心旅程与关键数据边界，Nightly/Release 扩展显式代表性集，不再用 Release 跑全部遗留 androidTest。
- 两仓库均实现 `focused/pr/nightly/release` 脚本、CI workflow、`AGENTS.md` 与 AI 增量开发规则。

## 新鲜证据

- Apple `swift test`：394 个 Swift Testing 测试、36 个 suite，以及 24 个 XCTest 全部通过。
- Apple iOS PR 核心纵向旅程 6/6 PASSED（空态、准确内容/详情/relaunch、搜索、删除撤销/relaunch、慢加载、失败/Retry）；结果包 `run-1-20260828-000450.xcresult`。
- Apple iOS `messages.standard`：准确标题/正文、详情、终止重启后仍一致，PASSED。
- Apple iOS 慢加载与失败/Retry：2/2 PASSED；空态纵向用例此前连续两次冷启动 PASSED。
- Apple iOS 搜索准确集合/详情、删除→立即隐藏→撤销→重启持久性均 PASSED；实跑发现并修复了待删除作用域未触发 `List` 重建及父可访问性标识覆盖 Undo 按钮两个产品缺陷。
- Apple iOS 真实点击四个主 Tab 并从频道页进入 Settings 的导航旅程 PASSED；Runtime 直接导航矩阵已退出常规 lane。
- Apple iOS Event 与 Thing 均已从真实 Tab、列表行进入详情并核对准确字段，PASSED。
- Apple Release Simulator 构建 PASSED；合法 Quality Session 注入在 Release 中无效，负控 PASSED。
- Android JVM：275 tests PASSED；`compileDebugAndroidTestKotlin` 与 Release APK 构建 PASSED。
- Android API 37 emulator：消息/搜索/删除撤销/慢失败恢复/真实导航/Event 准确详情/Thing 三关系页签纵向旅程 9/9 PASSED；隔离的迁移/删除/ACK 核心数据集 18/18 PASSED。
- 首个 Android emulator 在开测前消失，0 tests，分类为 `BLOCKED_TRANSIENT_RUNNER`；仅一次受控恢复后通过，未把首轮伪装成绿色。
- macOS UI target 已编译；执行被 macOS 系统自动化认证阻断，保持 `BLOCKED`。

## 已完成切片的本轮证据

- 两仓静态检查、单元测试、编译、Release 构建与代表性 UI/数据旅程均已完成；详见“新鲜证据”。
- 红蓝审计、归因分析、双向覆盖反查和残余风险已记录在 `validation.md`；这是同上下文证据，不是独立审查。
- 提交边界：按可独立验证的体系切片分别提交 Apple 与 Android；不 push、不发布。本表不以提交数量作为完成判据。

## 当前执行切片

1. 修复完成状态失真，逐项用第 21.2 节和第 25 节核账；
2. 让每次 lane 分别报告 `product_capability_status` 与 `test_system_status`，并列出本次实际执行 claim 与 `not_run`，禁止把局部绿色解释为全产品覆盖；
3. Android PR 增加代表 emulator 上的核心 App UI 旅程，不再只编译 `androidTest`；
4. Android Event/Thing 已按独立能力类完成首批准确内容、三个关系页签与 relaunch 证据；下一高价值迁移转向 Messages 分页/refresh/mark-read 与 Event close/Channel/Settings。

## 需要 Release/外部环境的明确证据

- 真实 APNs/FCM、通知中心动作、权限、Doze/后台、安装升级、签名、Widget/Spotlight/Intent/Live Activity、Watch 与物理可访问性任务。
- macOS UI 执行在系统认证授权前为 `BLOCKED`。
- Android Macrobenchmark 模块和物理设备性能基线尚未建立；当前慢加载用例证明状态与 Oracle，不声称真实设备性能预算已通过。
- 100k 数据量只在 opt-in 性能 lane 执行，不进入日常回归。

这些项目不得被模拟器绿色覆盖；它们需要真实平台或发布环境，必须在 Release 证据清单中独立报告。但 WP3–WP6 中仍可在本地/模拟器完成的功能缺口不能混入此清单。其余极端设备×语言×状态组合按风险等价采样，不构造全笛卡尔积。若某边缘用例不能对应高影响失败、历史事故或独有技术风险，则不实现或不进入常规 lane。
