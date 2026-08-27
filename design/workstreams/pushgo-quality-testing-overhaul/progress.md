# PushGo 全栈质量体系实施进度

## 状态

核心自动化底座与高价值纵向切片已实施并完成本轮验证；剩余工作只保留必须由真机/外部系统提供的发布证据。低价值边缘组合不进入日常门禁。

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
- Android JVM：274 tests PASSED；`compileDebugAndroidTestKotlin` 与 Release APK 构建 PASSED。
- Android API 37 emulator：消息/搜索/删除撤销/慢失败恢复/真实导航纵向旅程 7/7 PASSED；隔离的迁移/删除/ACK 核心数据集 18/18 PASSED。
- 首个 Android emulator 在开测前消失，0 tests，分类为 `BLOCKED_TRANSIENT_RUNNER`；仅一次受控恢复后通过，未把首轮伪装成绿色。
- macOS UI target 已编译；执行被 macOS 系统自动化认证阻断，保持 `BLOCKED`。

## 本轮实施收口

- 两仓静态检查、单元测试、编译、Release 构建与代表性 UI/数据旅程均已完成；详见“新鲜证据”。
- 红蓝审计、归因分析、双向覆盖反查和残余风险已记录在 `validation.md`。
- 提交边界：Apple 与 Android 各一个实现提交；不 push、不发布。

## 明确保留为 Release/NOT RUN 的证据

- 真实 APNs/FCM、通知中心动作、权限、Doze/后台、安装升级、签名、Widget/Spotlight/Intent/Live Activity、Watch 与物理可访问性任务。
- macOS UI 执行在系统认证授权前为 `BLOCKED`。
- Android Macrobenchmark 模块和物理设备性能基线尚未建立；当前慢加载用例证明状态与 Oracle，不声称真实设备性能预算已通过。
- 100k 数据量只在 opt-in 性能 lane 执行，不进入日常回归。

这些不是被自动化绿色覆盖的遗漏；它们需要真实平台或发布环境，必须在 Release 证据清单中独立报告。其余极端设备×语言×状态组合按风险等价采样，不构造全笛卡尔积。若某边缘用例不能对应高影响失败、历史事故或独有技术风险，则不实现或不进入常规 lane。
