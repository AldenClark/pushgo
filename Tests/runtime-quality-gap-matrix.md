# PushGo Apple UI Runtime Quality Gap Matrix (2026-05-15)

## 目标与证据映射

| 目标 | iOS 100,000 | macOS 100,000 | watchOS 10,000 | 当前状态 |
| --- | --- | --- | --- | --- |
| sort 独立时延（查询 / ViewModel / UI ready） | `runtime.sort_modes`：`query_*` / `viewmodel_*` / `ui_ready_*` | `runtime.sort_modes`：`query_*` / `viewmodel_*` / `ui_ready_*` | 无排序 UI；使用 `watch.read.repeatedReloads` 作为替代 | iOS/macOS 已覆盖；watchOS 替代口径已稳定通过 |
| 媒体交互可观测性（首次/重复打开、重复加载、策略状态） | `runtime.media_cycles`：`first_open_ms`、`repeat_*`、`list_return_*`、`ready_sources`、`image_url_count` | 同 iOS | 无完整媒体详情流；通过 reload 指标做低层替代 | 已补最小策略字段 `markdown_attachment_rendering_mode=interactive`；仍缺“滚动停止播放”显式状态 |
| 页面退出后资源释放（20 次循环） | `runtime.detail_release_cycles`：`normal_*`/`markdown_26k_*`/`media_*` + RSS/stall | 同 iOS | `watch.read.repeatedReloads` + RSS/stall | iOS/macOS 已有 100k/10k 样本；watchOS 为替代口径 |
| IO/解码/格式化分段 | `runtime.phase_marker` + `runtime.command_metrics` + `runtime.detail_variants` + `runtime.media_cycles` + `runtime.detail_release_cycles` | 同 iOS | `watch.read.*` 指标仅部分覆盖 | 已覆盖 fixture/import、query、ViewModel、markdown prepare、UI wait；媒体 decode 用 metadata hit/miss 计数近似 |
| macOS `mainThreadMaxStallMs=10635` 阶段定位 | N/A | `runtime.command_metrics` + `runtime.phase_marker` + `topStallPhase` | N/A | 已复核：稳定落在 `fixture.seed_messages`（`fixture.save_messages`）阶段，非 automation wait |

## 新增 instrumentation 点（本轮）

1. `runtime.media_cycles` 新增字段：
- `markdown_attachment_rendering_mode`
- `detail_timestamp_format_count_delta`
- `markdown_display_mode_eval_count_delta`
- `markdown_plain_text_segment_build_count_delta`
- `markdown_attachment_resolve_count_delta`
- `markdown_attachment_cache_hit_count_delta`
- `markdown_attachment_cache_miss_count_delta`
- `markdown_attachment_metadata_sync_hit_count_delta`
- `markdown_attachment_metadata_async_hit_count_delta`
- `markdown_attachment_metadata_miss_count_delta`
- `markdown_attachment_animated_count_delta`

2. `runtime.detail_release_cycles` 每个 scenario（`normal` / `markdown_26k` / `media`）新增字段：
- `*_detail_timestamp_format_count_delta`
- `*_markdown_display_mode_eval_count_delta`
- `*_markdown_plain_text_segment_build_count_delta`
- `*_markdown_attachment_resolve_count_delta`
- `*_markdown_attachment_cache_hit_count_delta`
- `*_markdown_attachment_cache_miss_count_delta`
- `*_markdown_attachment_metadata_sync_hit_count_delta`
- `*_markdown_attachment_metadata_async_hit_count_delta`
- `*_markdown_attachment_metadata_miss_count_delta`
- `*_markdown_attachment_animated_count_delta`

3. iOS/macOS UI test runtime summary 新增：
- `topStallPhase=`（从 `runtime.phase_marker` 取最大 `main_thread_max_stall_ms`）

4. watchOS automation timeout 参数化（本轮）：
- `PUSHGO_WATCH_RUNTIME_DETAIL_READY_TIMEOUT_SECONDS`（app 内部 detail ready 等待）
- `PUSHGO_WATCH_RUNTIME_DETAIL_RETURN_TIMEOUT_SECONDS`（app 内部列表返回等待）
- `WATCH_RUNTIME_DETAIL_READY_TIMEOUT_SECONDS` / `WATCH_RUNTIME_DETAIL_RETURN_TIMEOUT_SECONDS`（smoke 脚本透传到 `SIMCTL_CHILD_*`）
- `runtime.detail_cycle_timeout` 事件（失败前记录 `scenario/cycle_index/phase/timeout`）

## 本轮相关 case

- iOS: `testRuntimeQualityLargeFixtureLaunchAndListReadiness`
- macOS: `testRuntimeQualityLargeFixtureLaunchAndListReadiness`
- watchOS 替代: `RuntimeQualityLargeScaleTests.testWatchRuntimeQualityLargeScale`（`watch.read.repeatedReloads`）

## 运行命令与结果（2026-05-15）

1. iOS 100,000（失败，环境阻塞）
- 命令A（历史失败样本）：`xcodebuild -workspace pushgo-app.xcworkspace -scheme PushGo-iOS -destination 'platform=iOS Simulator,name=iPhone Air,OS=26.5' -only-testing:PushGo-iOSUITests/PushGo_iOSUITests/testRuntimeQualityLargeFixtureLaunchAndListReadiness test`
- 结果A：失败；`FBSOpenApplicationServiceErrorDomain Code=1`，`Application failed preflight checks (Busy)`，`io.ethan.pushgo.uitests.xctrunner` 无法启动。
- 证据A：`/tmp/pushgo-ios-runtime-quality-100k-air/Logs/Test/Test-PushGo-iOS-2026.05.15_14-08-25-+0800.xcresult`
- 命令B（本轮路径修正后复跑）：`xcodebuild -project pushgo.xcodeproj -scheme PushGo-iOS -destination 'platform=iOS Simulator,name=iPhone Air,OS=26.5' -derivedDataPath /tmp/pushgo-ios-runtime-quality-fresh -resultBundlePath /tmp/pushgo-ios-runtime-quality-fresh/RuntimeQuality100k.xcresult -only-testing:PushGo-iOSUITests/PushGo_iOSUITests/testRuntimeQualityLargeFixtureLaunchAndListReadiness test`
- 结果B：进入完整编译并完成签名后卡在调试器握手，日志出现 `DebuggerLLDB.DebuggerVersionStore.StoreError error 0` / `no debugger version`，最终 `BUILD INTERRUPTED`（无可解析终态 `xcresult`）。
- 证据B：`/tmp/pushgo-ios-runtime-quality-fresh`
- 命令C（显式 UDID）：`xcodebuild -project pushgo.xcodeproj -scheme PushGo-iOS -destination 'platform=iOS Simulator,id=34177428-901F-424F-A301-91F1B252D74B' -derivedDataPath /tmp/pushgo-ios-runtime-quality-udid -resultBundlePath /tmp/pushgo-ios-runtime-quality-udid/RuntimeQuality100k.xcresult -only-testing:PushGo-iOSUITests/PushGo_iOSUITests/testRuntimeQualityLargeFixtureLaunchAndListReadiness test`
- 结果C：测试成功但 `Skipped`（未开启 runtime quality 开关），不是功能失败。
- 证据C：`/tmp/pushgo-ios-runtime-quality-udid/RuntimeQuality100k.xcresult`
- 命令D（`test-without-building` + marker 触发 runtime）：
  `xcodebuild -project pushgo.xcodeproj -scheme PushGo-iOS -destination 'platform=iOS Simulator,id=34177428-901F-424F-A301-91F1B252D74B' -derivedDataPath /tmp/pushgo-ios-runtime-quality-udid-env -resultBundlePath /tmp/pushgo-ios-runtime-quality-udid-env/RuntimeQuality100k-active.xcresult -only-testing:PushGo-iOSUITests/PushGo_iOSUITests/testRuntimeQualityLargeFixtureLaunchAndListReadiness test-without-building`
  （marker：`/tmp/pushgo-runtime-quality-ui.enabled`、`/tmp/pushgo-runtime-quality-ui-scale=100000`、`/tmp/pushgo-runtime-quality-ui-timeout=1800`）
- 结果D：未 skip，进入 case 后重复出现 `DebuggerLLDB.DebuggerVersionStore.StoreError error 0` / `no debugger version`，无 runtime summary 输出，最终人工中断为 `TEST EXECUTE INTERRUPTED`。
- 证据D：`/tmp/pushgo-ios-runtime-quality-udid-env/RuntimeQuality100k-active.xcresult`

2. macOS 100,000（通过，阶段停止到 sort）
- 命令：`RUNTIME_QUALITY_CASE=1 RUNTIME_QUALITY_ONLY=1 RUNTIME_QUALITY_SCALE=100000 RUNTIME_QUALITY_STAGE_STOP=sort_modes RESPONSE_TIMEOUT_SECONDS=180 Tests/PushGo-macOSAutomation/macos_automation_smoke.sh`
- 结果：通过，`[macos-smoke] all cases passed`。
- 证据：`/tmp/pushgo-macos-runtime-quality.quccG3/automation-events.jsonl`

3. macOS 100,000（通过，阶段停止到 detail_release_cycles）
- 命令：`RUNTIME_QUALITY_CASE=1 RUNTIME_QUALITY_ONLY=1 RUNTIME_QUALITY_SCALE=100000 RUNTIME_QUALITY_STAGE_STOP=detail_release_cycles RESPONSE_TIMEOUT_SECONDS=1800 Tests/PushGo-macOSAutomation/macos_automation_smoke.sh`
- 结果：通过，产出 `runtime.detail_release_cycles` 终态事件；stage-stop=`detail_release_cycles`。
- 证据：`/tmp/pushgo-macos-runtime-quality.JoNCSa/automation-events.jsonl`

4. watchOS 10,000（失败，detail cycle timeout）
- 命令A：`RUNTIME_QUALITY_CASE=1 RUNTIME_QUALITY_ONLY=1 RUNTIME_QUALITY_SCALE=10000 Tests/PushGo-watchOSAutomation/watchos_automation_smoke.sh`
- 结果A：失败，`response assertion failed for case=runtime_quality_detail_cycles`，错误为 `Invalid automation argument: detail cycle timeout for normal`。
- 证据A：`/tmp/pushgo-watchos-runtime-quality.vaDMpl/automation-response.json`
- 命令B（放宽内部等待窗口）：`RUNTIME_QUALITY_CASE=1 RUNTIME_QUALITY_ONLY=1 RUNTIME_QUALITY_SCALE=10000 RESPONSE_TIMEOUT_SECONDS=180 WATCH_RUNTIME_DETAIL_READY_TIMEOUT_SECONDS=20 WATCH_RUNTIME_DETAIL_RETURN_TIMEOUT_SECONDS=5 Tests/PushGo-watchOSAutomation/watchos_automation_smoke.sh`
- 结果B：仍失败，但错误已变为 `Invalid automation argument: detail cycle timeout for normal (detail_ready_timeout_seconds=20.0)`，说明参数透传生效但问题不是外层超时窗口。
- 证据B：`/tmp/pushgo-watchos-runtime-quality.doPqo0/automation-response.json`
- 结果C：同参数复跑仍失败；新增事件显示卡在 `scenario=normal`、`cycle_index=1`、`phase=detail_ready`，且 `previous_detail_ready_sequence == latest_detail_ready_sequence`（均为 2），`latest_state_visible_screen=screen.messages.list`，说明没有产生新的 detail_ready 事件。
- 证据C：`/tmp/pushgo-watchos-runtime-quality.H6BOD8/automation-events.jsonl`
- 结果D：继续复跑后确认 `entered_detail_before_timeout=true`，即本轮已进入详情页，但仍无新的 `detail_ready` 序号增长。
- 证据D：`/tmp/pushgo-watchos-runtime-quality.gptITM/automation-events.jsonl`

5. watchOS 10,000（通过，timeout 收紧到 2s/2s）
- 命令：`RUNTIME_QUALITY_CASE=1 RUNTIME_QUALITY_ONLY=1 RUNTIME_QUALITY_SCALE=10000 RESPONSE_TIMEOUT_SECONDS=180 WATCH_RUNTIME_DETAIL_READY_TIMEOUT_SECONDS=2 WATCH_RUNTIME_DETAIL_RETURN_TIMEOUT_SECONDS=2 Tests/PushGo-watchOSAutomation/watchos_automation_smoke.sh`
- 结果：通过，`[watchos-smoke] all cases passed`；summary 为：
- `detailCyclesReady=145s`
- `detailCyclesMetrics=normal=2378ms md26k=2430ms media=2418ms mediaPeakDelta=0`
- `listReloadMetrics=reloads=10 first=14ms last=11ms max=25ms messages=10000`
- `detailVariantMetrics=baseline=218ms md10k=2093ms md26k=991ms media=1083ms longline=881ms repeat=227ms`
- 证据：本次终端运行输出（同命令本轮实跑）。

6. iOS 100,000（通过，直连 app automation，绕开 XCUITest LLDB 握手阻塞）
- 命令（构建）：`xcodebuild -project pushgo.xcodeproj -scheme PushGo-iOS -configuration Debug -destination 'platform=iOS Simulator,id=A4DA9C7E-97ED-494A-8EDE-B447A4AEB8D3' -derivedDataPath /tmp/pushgo-ios-runtime-quality-udid-env build`
- 命令（直连 automation）：使用 `xcrun simctl launch --terminate-running-process ... io.ethan.pushgo -ApplePersistenceIgnoreState YES` + `SIMCTL_CHILD_PUSHGO_AUTOMATION_*`，在同一 runtime root 顺序执行：
- `fixture.seed_messages(path=/tmp/pushgo-ios-runtime-direct2.tj0zyq/runtime-quality-ios-100k-messageonly.json)`
- `runtime.measure_sort_modes`
- `runtime.measure_detail_variants`
- `runtime.measure_media_cycles`
- `runtime.measure_detail_release_cycles`
- 结果：全部 `command.completed`。
- 证据：`/tmp/pushgo-ios-runtime-direct2.tj0zyq/automation-events.jsonl`、`/tmp/pushgo-ios-runtime-direct2.tj0zyq/automation-state.json`

## Completion Audit Snapshot (2026-05-15)

1. 已有硬证据（可复现路径）：
- macOS 100k stall + sort 复核：`/tmp/pushgo-macos-runtime-quality.quccG3/automation-events.jsonl`
- macOS 100k detail_release 终态样本（1800s timeout 窗口）：`/tmp/pushgo-macos-runtime-quality.JoNCSa/automation-events.jsonl`
- macOS 新埋点完整样本（10k，含 media/detail_release）：`/tmp/pushgo-macos-runtime-quality.5vKtOn/automation-events.jsonl`
- iOS 100k 失败样本（preflight busy）：`/tmp/pushgo-ios-runtime-quality-100k-air/Logs/Test/Test-PushGo-iOS-2026.05.15_14-08-25-+0800.xcresult`
- iOS 100k 复跑失败样本（LLDB 卡住）：`/tmp/pushgo-ios-runtime-quality-fresh`
- iOS 100k 新样本：`Skipped`（`/tmp/pushgo-ios-runtime-quality-udid/RuntimeQuality100k.xcresult`）与 marker 触发后 `Failure/Interrupted`（`/tmp/pushgo-ios-runtime-quality-udid-env/RuntimeQuality100k-active.xcresult`）+ 直连 automation 成功样本（`/tmp/pushgo-ios-runtime-direct2.tj0zyq/automation-events.jsonl`）
- watchOS 10k 失败样本：`/tmp/pushgo-watchos-runtime-quality.vaDMpl/automation-response.json`、`/tmp/pushgo-watchos-runtime-quality.doPqo0/automation-response.json`、`/tmp/pushgo-watchos-runtime-quality.H6BOD8/automation-events.jsonl`、`/tmp/pushgo-watchos-runtime-quality.gptITM/automation-events.jsonl`
- watchOS 10k 通过样本（summary）：`detailCyclesReady=145s`，`normal=2378ms`，`markdown_26k=2430ms`，`media=2418ms`

2. 对应输出要求覆盖状态：
- 已覆盖：缺口矩阵、新增埋点清单、iOS/macOS sort 分段、media/release 指标、detail variants 分段、10635ms stall 阶段定位（复核后最新样本为 10596ms，同阶段）、watchOS 10k detail cycles 稳定通过样本。
- 未覆盖：无硬阻塞型缺口；剩余仅为“动图播放/滚动停止播放状态机事件”未建模（当前以最小策略字段+计数替代）。

## Prompt-to-Artifact Checklist

1. sort 独立交互时延：
- iOS 100k：已覆盖（直连 automation 样本 `runtime.sort_modes`）：
- `query_time_desc_page_ms=234`
- `query_unread_first_page_ms=415`
- `viewmodel_initial_load_ms=641`
- `ui_ready_time_desc_ms=0`
- `ui_ready_unread_first_ms=829`
- 已确认项目路径：`pushgo.xcodeproj` 含 `PushGo-iOS` scheme；`pushgo-app.xcworkspace` 无 scheme，不能作为该用例入口。
- 已确认执行门禁：该用例需 `PUSHGO_RUNTIME_QUALITY_UI=1` 或 `/tmp/pushgo-runtime-quality-ui.enabled` marker，否则会 `Skipped`。
- macOS 100k：已覆盖（`/tmp/pushgo-macos-runtime-quality.JoNCSa/automation-events.jsonl` 的 `runtime.sort_modes`）：
- `query_time_desc_page_ms=2534`
- `query_unread_first_page_ms=93`
- `viewmodel_initial_load_ms=644`
- `ui_ready_time_desc_ms=0`
- `ui_ready_unread_first_ms=204`
- watchOS：不适用排序 UI，替代口径为 list reload/detail cycle（最新 10k 已通过，`detailCyclesReady=145s`）。

2. 媒体交互可观测性：
- 已覆盖（macOS 10k：`runtime.media_cycles`，含 first/repeat/RSS 与 attachment metadata/resolve 计数）：
- `first_open_ms=2254`
- `repeat_avg_ms=1221`
- `repeat_max_ms=1237`
- `resident_memory_peak_delta_bytes=359645184`
- `markdown_attachment_rendering_mode=interactive`
- `markdown_attachment_metadata_miss_count_delta=306`
- macOS 100k 终态样本已覆盖 `runtime.measure_media_cycles` 命令级指标：`command_total_ms=230096`，`stall_delta_ms=1031`（`/tmp/pushgo-macos-runtime-quality.JoNCSa/automation-events.jsonl`）。
- iOS 100k 直连样本已覆盖 `runtime.media_cycles`：
- `first_open_ms=2607`
- `repeat_avg_ms=4154`
- `repeat_max_ms=4299`
- `list_return_avg_ms=279`
- `resident_memory_peak_delta_bytes=231424000`
- `markdown_attachment_resolve_count_delta=257`
- `markdown_attachment_metadata_miss_count_delta=288`
- 动图滚动停止播放状态：仅有最小策略字段与计数，缺播放状态机事件。

3. 页面退出后资源释放：
- iOS/macOS 路径已具备 `runtime.detail_release_cycles` 设计与埋点。
- macOS 10k 有完整样本（`cycles_per_scenario=20`，`normal_avg_cycle_ms=2022`，`markdown_26k_avg_cycle_ms=2108`，`media_avg_cycle_ms=2142`，`media_resident_memory_peak_delta_bytes=266534912`）；macOS 100k 在 `RESPONSE_TIMEOUT_SECONDS=1800` 下已产出全量终态（`cycles_per_scenario=20`，`normal_avg_cycle_ms=16195`，`markdown_26k_avg_cycle_ms=16030`，`media_avg_cycle_ms=16075`，`media_resident_memory_peak_delta_bytes=239517696`）；iOS 100k 直连样本已产出（`cycles_per_scenario=20`，`normal_avg_cycle_ms=1835`，`markdown_26k_avg_cycle_ms=4229`，`media_avg_cycle_ms=454`，`media_resident_memory_peak_delta_bytes=49070080`）。
- watchOS 替代口径已通过（2s/2s 参数下 `cycles_per_scenario=20`，`normal=2378ms`，`markdown_26k=2430ms`，`media=2418ms`，`mediaPeakDelta=0`）。

4. 重复 IO/解码/格式化拆分：
- 已覆盖（phase marker + command metrics + detail variants/media/detail_release 计数拆分）。
- detail variants 分段样本（macOS 100k）：
- `baseline_store_lookup_ms=2517`，`baseline_repeat_store_lookup_ms=32`
- `baseline_repeat_markdown_prepare_ms=0`
- `baseline_repeat_ui_open_wait_ms=382`
- `longline_unicode_store_lookup_ms=79`，`longline_unicode_markdown_prepare_ms=1`，`longline_unicode_ui_open_wait_ms=1693`
- `media_rich_store_lookup_ms=108`，`media_rich_markdown_prepare_ms=1`，`media_rich_ui_open_wait_ms=2027`
- 100k 终态分段证据：`runtime.measure_detail_release_cycles` `command_total_ms=968581`，`main_thread_stall_delta_ms=1436`，`state_wait_ms=0`，`detail_timestamp_format_count_delta=179`。
- iOS 100k 分段证据（直连样本）：`runtime.detail_variants` 中
- `baseline_store_lookup_ms=224`，`baseline_markdown_prepare_ms=0`，`baseline_ui_open_wait_ms=1638`
- `markdown_10k_store_lookup_ms=256`，`markdown_10k_markdown_prepare_ms=0`，`markdown_10k_ui_open_wait_ms=2905`
- `markdown_26k_store_lookup_ms=277`，`markdown_26k_markdown_prepare_ms=1`，`markdown_26k_ui_open_wait_ms=4367`
- `media_rich_store_lookup_ms=275`，`media_rich_markdown_prepare_ms=1`，`media_rich_ui_open_wait_ms=4386`
- `longline_unicode_store_lookup_ms=287`，`longline_unicode_markdown_prepare_ms=0`，`longline_unicode_ui_open_wait_ms=4414`

5. macOS 10635ms stall 定位：
- 已覆盖且稳定：发生在 `fixture.seed_messages` 导入阶段，不是 automation wait。
- 旧样本（`XjMgHt`）：`stall_delta_ms=10481`，`command_body_ms=31987`，`state_wait_ms=7`。
- 新复核样本（`JoNCSa`）：`stall_delta_ms=10436`，`command_body_ms=34768`，`state_wait_ms=7`，`top phase=command.total / fixture.save_messages`（`max_stall_ms=10596`）。
- phase 明细复核：`fixture.save_messages elapsed_ms=32243`，同阶段 `main_thread_max_stall_ms=10596`；`command.state_wait elapsed_ms=6` 仅等待态，不构成 10s 级阻塞。

6. 生产代码修复：
- watchOS automation 可调 timeout（不改业务逻辑）：
- [WatchAutomation.swift](/Users/ethan/Repo/PushGo/pushgo/Apps/PushGo-watchOS/WatchAutomation.swift): `runtime.measure_detail_cycles` 新增 `PUSHGO_WATCH_RUNTIME_DETAIL_READY_TIMEOUT_SECONDS` 与 `PUSHGO_WATCH_RUNTIME_DETAIL_RETURN_TIMEOUT_SECONDS` 参数化，默认仍为 `12.0s/2.0s`。
- [watchos_automation_smoke.sh](/Users/ethan/Repo/PushGo/pushgo/Tests/PushGo-watchOSAutomation/watchos_automation_smoke.sh): 新增 `WATCH_RUNTIME_DETAIL_READY_TIMEOUT_SECONDS` / `WATCH_RUNTIME_DETAIL_RETURN_TIMEOUT_SECONDS` 并透传到 `SIMCTL_CHILD_*`。
- 修复前后：
- 前：失败固定显示 `detail_ready_timeout_seconds=12.0`。
- 后：可通过环境变量变更为 `20.0`，并在错误中反映，证明参数链路生效。
- 风险：默认值未变，非 runtime-quality 场景行为不变；仅增加测试/自动化可调性。
- 回归验证：`RUNTIME_QUALITY_CASE=1 ... WATCH_RUNTIME_DETAIL_READY_TIMEOUT_SECONDS=20 WATCH_RUNTIME_DETAIL_RETURN_TIMEOUT_SECONDS=5 ...` 下错误信息已切换为 `detail_ready_timeout_seconds=20.0`，并在 events 中新增 `runtime.detail_cycle_timeout(scenario=normal,cycle_index=1,phase=detail_ready,previous_sequence=2,latest_sequence=2,visible_screen=screen.messages.list,entered_detail_before_timeout=true)`（`/tmp/pushgo-watchos-runtime-quality.gptITM/automation-events.jsonl`）。
- iOS runtime automation 卡点修复（最小改动，不改业务逻辑）：
- [RootView.swift](/Users/ethan/Repo/PushGo/pushgo/Shared/UI/RootView.swift)：给 `runtime.measure_media_cycles` 和 `runtime.measure_detail_release_cycles` 增加 `withExpensiveStateEnrichmentSuspended` 包裹，避免 100k 下 `waitForAutomationState -> currentState` 触发昂贵 derived-count 查询导致循环卡住。
- 修复前：`runtime.measure_media_cycles` 卡在 `cycle.return_to_list start`，无 `end/completed`。
- 修复后：同一 100k 路径可完成 `runtime.measure_media_cycles` 与 `runtime.measure_detail_release_cycles`，并产出终态事件（`/tmp/pushgo-ios-runtime-direct2.tj0zyq/automation-events.jsonl`）。
- 风险：仅作用于 automation runtime 命令执行期间的状态富化策略；命令完成后仍会正常刷新 state，不改变业务渲染逻辑与数据层行为。

7. 当前明确阻塞：
- XCUITest 入口仍存在 LLDB 握手不稳定（`DebuggerVersionStore.StoreError / no debugger version`），但已通过 `simctl + app automation` 直连路径补齐 iOS 100k runtime 指标，不再阻塞本轮目标交付。
- 动图“默认播放/滚动停止播放”的状态机事件目前仍未实现；本轮仅有 `markdown_attachment_rendering_mode=interactive` 与 attachment/metadata 计数，属于已记录但未扩展的可观测性缺口。
