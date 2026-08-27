# Apple WP0 质量基线

采集时间：2026-08-27。所有计数是候选风险信号，不是质量分数；只有逐调用路径审查才能确定处置。

## 新鲜执行证据

| 检查 | 结果 | 证据边界 |
| --- | --- | --- |
| `swift test` | PASSED：24 XCTest；393 Swift Testing tests/36 suites | Core/Store/集成；100k opt-in runtime-quality 未启用 |
| iOS `testLaunchesIntoMessageList` | PASSED：1/1，当前 iOS 27.0 Simulator，66.5s（含构建） | 只证明旧 smoke 的 screen-id Oracle；不证明内容、慢加载或性能 |
| iOS Event 关闭纵向旅程（WP0 后续迁移证据） | PASSED：1/1，iOS 27.0 Simulator；结果包 `run-1-20260828-040321.xcresult` | 证明真实详情确认关闭、canonical projection 更新、仅进行中筛选排除以及同 session relaunch 后 closed 持久化；不证明 slow/error/duplicate close 或真实 Gateway |
| Android/物理 Apple/真实推送 | NOT RUN | WP0 当前无 Android device；真实系统不由本基线替代 |

## 现有 Apple UI 测试形态

| 信号 | 当前值 | 解释 |
| --- | ---: | --- |
| iOS + macOS UI tests | 47 | 数量不代表能力覆盖 |
| Runner→App automation state/response/events 路径环境变量赋值 | 6 | 跨沙箱绝对路径协议必须移除 |
| macOS `automationArtifactsAvailable` 后直接 return | 12 | artifact 不可见时可能假绿 |
| `stateURL/responseURL/eventsURL` 引用 | 160 | 内部文件与最终 Oracle 高度耦合 |
| Runtime 导航/打开/设置 command 候选 | 39 | 可能绕过真实用户旅程，逐项重写/移动 |
| 固定 `sleep/usleep` | 0 | 当前主要同步问题不是固定 sleep，而是文件轮询/宽 timeout |
| `XCTSkip` | 2 | 需保持明确 Lane；不能汇总成通过 |

## 首个可证伪基线结论

当前启动 smoke 可以通过，即使它只看到 `screen.messages.list`，并未证明 Store 数据加载、Empty/Content/Error 区分、字段正确或用户可操作。因此这条绿色不能捕获本次“数据加载很慢且未及时预警”的问题，是 WP1/WP2 必须替换的首个弱 Oracle。

## 当前执行阻力

- `scripts/run_ios_ui_tests.sh` 固定 `iPhone 17e / iOS 26.4`，当前实际可用 Simulator 是 iOS 27.0；脚本无法直接使用现有设备。
- 脚本默认允许最多两次 transient runner retry；第一次失败证据虽保留在当次日志，最终汇总仍需显式标成 FLAKY。
- 现有成功 smoke 由动态选择当前 booted Simulator 的工具执行；WP1 要把动态选择和结构化 preflight 固化到仓库脚本。

## WP0 退出裁决

- 导出 helper 与 `MacMenuBarContentView` 未发现真实产品入口，列为删除候选，不为其接通入口或新增 UI 测试。
- WP0 于 2026-08-27 退出；旧 smoke 的绿色只保留为 runner 诊断，不计入功能覆盖。
