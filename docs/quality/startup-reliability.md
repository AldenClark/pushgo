# Hermetic 启动可靠性合同

## 目的与边界

该合同回答的不是“进程能不能偶尔拉起”，而是：测试是否能连续创建隔离的 App-owned 会话，并让用户真正到达可操作、数据准确的功能终点。两端默认使用 `empty.clean`，每轮最终要求 Messages 功能空态成立，同时确认产品 Store/Room 不是生产数据库；readiness、文件、Runner 退出码本身都不是产品 Oracle。

这是 opt-in 治理证据，不进入每次 PR。以下情况执行完整 50 次：测试 Runtime、启动生命周期、Store 初始化、Runner/Simulator/Emulator 版本或 active flake 归因发生实质变化；日常变更继续使用 Focused/PR Lane。这样既能守住“经常跑不了”的高价值风险，也不把 50 次重复任务变成日常预算黑洞。

## 可执行入口

```bash
# Apple iOS：专用 PushGo Quality iPhone Simulator；XCTest repetition 每轮重启测试进程
scripts/run_ios_startup_reliability.sh

# Apple macOS：当前已解锁的受控本机桌面；每轮独立 XCTest invocation，持续清理崩溃弹窗
scripts/run_macos_startup_reliability.sh

# Android：只允许 quality_doctor 选出的受控 emulator，禁止个人设备
../pushgo-android/scripts/run_android_startup_reliability.sh
```

三个入口默认 `ITERATIONS=50`，先构建一次，正式样本不启用 retry-on-failure。iOS 使用 XCTest repetition 重启测试进程；macOS 为避开 repetition runner 自身偶发的 `Running Background` 激活故障，每轮使用独立的 `test-without-building` invocation 和 xcresult，这些都是预先计划的独立样本，不是失败重试。`ITERATIONS=1` 只用于命令校准，不能满足完成条件；非法范围在接触设备或桌面前 `BLOCKED`。每个 campaign 使用唯一结果目录，保留逐次结果、原始日志/xcresult 或 Android iteration 表和机器可读 `summary.json`。macOS 每轮除准确空态外，还必须完成 Settings→Messages 的真实导航往返并再次落到准确空态；外层监控会持续关闭系统崩溃窗口，但绝不改变产品失败或重跑断言。

## 结果合同

- `success_rate >= 98%`：满足设计中的 Hermetic 启动门槛；低于门槛时该工作包不通过。
- 只有 `50/50` 且没有 issue ID，才可作为“连续 50 次稳定”的候选退出证据。
- App-owned session、fixture、数据库或 readiness 准备失败：product=`NOT_RUN`、test-system=`BLOCKED`，零重试。
- 首个产品动作前的精确 Apple Simulator/Runner 已登记签名：test-system=`FLAKY/FAILED`，不得用剩余绿色隐藏。
- 已进入真实功能终点后，空态、隔离数据库或其他产品断言错误：product=`FAILED`，零重试。
- `PASSED/PASSED` 不携带 issue ID；局部启动 campaign 不提升整个 App、系统通知、真机或发布能力状态。

Apple 的 focused journey 正好覆盖 `apple-simulator-xctest-runner-launch` 的实际历史作用边界；2026-08-28 的干净 50/50 后，该登记已 resolved，通用 iOS Runner 默认与允许重试均改为 0。新的 Test Case 前未知 Runner 故障直接 `BLOCKED` 做新归因，不能恢复旧重试。Android focused startup 能证明 WP1 启动可靠性，但不能单独关闭 `android-compose-snapshot-observer-runtime`：后者发生在多旅程 Compose drawing 聚合运行中；除非执行与其 scope 一致的 50 次 device-class 证据，否则继续保留并按期处理。

## 红蓝负控

1. 把 `ITERATIONS` 设为 `0` 或 `101`，必须在 doctor/build/device 前退出 2，结果为 `BLOCKED`。
2. 删除或改错受控设备/Instrumentation 合同，必须在正式 iteration 前 `BLOCKED`，不得记产品失败。
3. 让真实空态断言失败，必须成为 product `FAILED`；不能因日志同时有 timeout/异常文本转为 test-system。
4. 注入 `QUALITY_PRECONDITION`，必须成为 `NOT_RUN/BLOCKED` 且零重试。
5. 49/50 即使达到 98%，也必须保留 `FLAKY` 或失败归因，不能满足 active flake 的连续退出条件。
6. Android 50 次 focused startup 不得生成“Compose aggregate flake 已关闭”的字段；报告显式保留 scope notice。
7. Android raw Instrumentation 日志同时含 Compose 已知签名和任一非 precondition `AssertionError` 时，必须以 product `FAILED` 为准且 issue ID 为空。

两周观察仍是独立治理条件。单次 50/50 只证明当前受控平台、当前 Xcode/SDK/Emulator 和当前 focused 功能终点，不能替代后续真实变更的 Lane 时长、启动失败率、业务失败率和 issue 到期审查。

## 2026-08-30 macOS 基线

- macOS 受控本机桌面：50 个独立 invocation 全部通过，product/test-system=`PASSED/PASSED`、issue ID 为空；p50=16.163s、p95=16.378s、max=19.405s；激活故障、Problem Reporter 清理和业务重试均为 0；`build/quality-results/macos-startup-reliability/20260830-135031/summary.json`。
- repetition 负证据：首轮 49/50 在第 37 轮出现 XCTest `Running Background` 激活超时；去除 helper 冗余激活后仍在后续 campaign 复现，App 启动侧试探性调整也没有消除，均撤回。该故障属于 repetition runner 共模，不允许用 98% 或后续绿色隐藏，也不归因给产品空态/导航。
- Oracle 负控：临时错误空态 identifier 后单轮精确输出 product=`FAILED`、test-system=`PASSED`，恢复后才执行正式 campaign。

## 2026-08-28 iOS/Android 基线

- iOS 专用 Simulator：50/50，product/test-system=`PASSED/PASSED`、issue ID 为空；p50=8.604s、p95=10.634s、max=13.875s；`build/quality-results/ios-startup-reliability/20260828-205055/summary.json`。
- Android 受控 `emulator-5554`：50/50，双状态通过、issue ID 为空；p50=1901.5ms、p95=9073ms、max=15226ms；`../pushgo-android/build/quality-results/android-startup-reliability/20260828-205052/summary.json`。

上述时长包含各平台测试框架/Instrumentation 与完整功能空态旅程，只是受控环境观测，不与物理设备用户 SLO 混用。随后当前差异的自动选择仍为普通 PR：Apple 11/11 核心 UI、Android JVM/编译/本地化均在不重复 50 次的情况下通过。
