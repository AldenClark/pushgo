# Apple 性能证据合同

性能通过必须回答“用户是否在预算内得到准确结果”，不能只回答查询函数快、文件存在或页面最终出现。

## 四层证据

1. `RuntimeQualityLargeScaleTests`：100k canonical Store、upgrade、search/page/filter、10k Watch/concurrency 的正确性、宿主耗时、RSS 和 main-thread stall。它只防数据层明显退化。
2. `testPreparedLargeMessageStoreColdLaunchReachesAccurateContent`：在测量外用 App-owned session 原子准备 1,000 条消息；同一持久化 session 冷启动 5 次，采集 `XCTApplicationLaunchMetric`、clock、CPU、memory。每次必须显示最高索引准确首行，完整 launch→content 不超过 8s Simulator 粗上限；最后打开该行并核对匹配正文。
3. `scripts/run_ios_physical_performance.sh`：只在显式专用参考设备执行 Release 配置 10 次；直接使用设备上通过真实 App/真实 ingress 准备的非个人 sentinel，不启用 Quality Runtime。标题及时出现后仍要打开并核对正文。
4. 归因 trace：只有前述预算失败时才对一个明确 flow 临时链接 ETTrace，保存 UUID 匹配、已 symbolicate 的 processed JSON 后立即移除。ETTrace 不常驻生产 target，也不参与日常绿色判定。

Apple 官方将 `XCTApplicationLaunchMetric` 定义为首帧及 extended launch task 的启动时长指标，并支持 clock/CPU/memory 等 `XCTMetric`；Xcode 性能测试可保存 baseline 和 tolerance。真实用户分布应另由 MetricKit/Xcode Organizer 观察，不能从 Simulator 外推。参考：[XCTApplicationLaunchMetric](https://developer.apple.com/documentation/xctest/xctapplicationlaunchmetric)、[Writing and running performance tests](https://developer.apple.com/documentation/xcode/writing-and-running-performance-tests)、[MetricKit](https://developer.apple.com/documentation/metrickit)、[ETTrace](https://github.com/EmergeTools/ETTrace)。

## 固定真机准备与执行

只能使用不会承载个人/生产数据的签名参考设备。先通过正式 UI、测试 Gateway 或真实 push ingress 写入一条最新 sentinel，记录精确标题和正文；不要直接复制数据库，也不要让 Runner 获得 App sandbox 权限。

```sh
IOS_PERFORMANCE_DEVICE_ID='<device-udid>' \
PUSHGO_PHYSICAL_EXPECTED_TITLE='Performance sentinel 2026-08-28' \
PUSHGO_PHYSICAL_EXPECTED_BODY='Exact persisted sentinel body.' \
PUSHGO_PHYSICAL_MAX_SECONDS='2.5' \
scripts/run_ios_physical_performance.sh
```

脚本不会自动选择个人真机，也不会回退到 Simulator。设备、签名或 Developer Mode 不满足时是 `BLOCKED`；准确内容或预算失败是 `FAILED`；未显式提供合同的普通 Lane 是 `NOT RUN`。结果 log 与 xcresult 保存在 `build/quality-results/ios-physical-performance/`。

## 基线与改基线

- 同一硬件型号、OS、Xcode、Release 配置、网络条件和 sentinel 数据量至少执行 10 次；首次启用建议 3 个独立批次。
- 从 xcresult/活动记录计算 p50/p95。批准预算不得宽于产品 SLO；若 baseline p95 已超过 SLO，先优化，不能用改大阈值求绿。
- 只有硬件、OS、编译器或明确产品工作量改变时才能重建 baseline；保留旧数据和理由。普通代码变慢不得改 baseline。
- Simulator 的 8s 只用于发现秒级退化，不进入真机 SLO，也不因一次本机更快就收紧为脆弱阈值。

## 失败后的归因顺序

1. 先确认 sentinel 仍准确、设备与构建身份正确，区分 `BLOCKED` 与产品 `FAILED`。
2. 对比 launch、clock、CPU、memory，判断是 process launch、数据读取、渲染还是资源增长。
3. 只对失败的单一 flow 获取 Release-like Instruments 或临时 ETTrace；无 symbolication 不下 first-party hotspot 结论。
4. 修复后重跑同一目的 Oracle，再跑受影响的 Store/功能回归；trace 只解释原因，不能替代最终用户结果。
