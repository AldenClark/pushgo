# PushGo watchOS Automation Matrix

## Scope

This is the legacy diagnostic matrix for the built-in `WatchAutomation` command/response/state/event protocol. Its internal state and artifact checks do **not** count as user-function evidence and its retries must not be used to turn a product failure green.

The authoritative representative UI regression target is `Tests/PushGo-watchOSUITests`, launched by `scripts/run_watchos_ui_tests.sh`. It uses App-owned hermetic scenarios and ends on visible product fields, real delete controls, automatic navigation recovery, and relaunch persistence. Keep this legacy suite only for protocol diagnosis and large-fixture support until its remaining useful cases are migrated.

## Coverage Matrix

| Case | Coverage |
| --- | --- |
| `nav_events` | `nav.switch_tab` routes to `screen.events.list` / `tab.events` |
| `nav_things` | `nav.switch_tab` routes to `screen.things.list` / `tab.things` |
| `fixture_event_import` | fixture import path validates event ingestion (`event_count >= 1`) |
| `fixture_thing_import` | fixture import path validates thing projection ingestion (`thing_count >= 1`) |
| `entity_open_event` | shared-runtime fixture + `entity.open` validates event detail state and target `entity.opened` event |
| `entity_open_thing` | shared-runtime fixture + `entity.open` validates thing detail state and target `entity.opened` event |
| `runtime_quality_large_fixture` | optional 10,000-message watch-light fixture import validates list readiness and store health |
| `runtime_quality_message_detail` | optional shared-runtime `message.open` validates detail readiness after large fixture import |

## Run Command

```bash
/Users/ethan/Repo/PushGo/pushgo/Tests/PushGo-watchOSAutomation/watchos_automation_smoke.sh
```

Serial full Apple pipeline entry:

```bash
/Users/ethan/Repo/PushGo/pushgo/Tests/PushGo-AppleAutomation/run_apple_automation_serial.sh
```

默认是串行冷启动模式（`COLD_BOOT=1`）并在结束后关机（`AUTO_SHUTDOWN=1`），用于降低模拟器卡住概率与资源占用。  
默认仅启动 watch 模拟器（`BOOT_IPHONE=0`）；只有需要联动时才开启 iPhone（`BOOT_IPHONE=1`）。
每个 case 默认最多重试 2 次（`CASE_RETRY_COUNT=2`），响应/状态等待默认 25 秒（`RESPONSE_TIMEOUT_SECONDS=25`）。
默认启用非交互签名参数（`NO_INTERACTIVE_SIGNING=1`）以减少系统密码/二次验证弹窗。
设备选择支持自动解析：优先使用 `WATCH_DEVICE_ID`/`IPHONE_DEVICE_ID`，找不到时按 `WATCH_DEVICE_NAME`/`IPHONE_DEVICE_NAME`，再回退到首个可用设备。
Apple automation 环境默认设置 `PUSHGO_AUTOMATION_ALLOW_CROSS_APP_DATA_ACCESS=0`，避免跨 App 数据访问弹窗阻塞。

大规模 runtime-quality 模式需要显式开启：

```bash
RUNTIME_QUALITY_ONLY=1 RUNTIME_QUALITY_CASE=1 RUNTIME_QUALITY_SCALE=10000 RESPONSE_TIMEOUT_SECONDS=180 CASE_RETRY_COUNT=1 /Users/ethan/Repo/PushGo/pushgo/Tests/PushGo-watchOSAutomation/watchos_automation_smoke.sh
```

## Diagnostic Pass Criteria

- All smoke cases complete successfully; this does not imply the corresponding UI capability passed.
- Each case emits non-empty `automation-events.jsonl`.
- `ok=true` cases must keep `runtime_error_count == 0` and avoid `local_store_mode=unavailable`.
- `entity.open` cases must emit a matching `entity.opened(entity_id=target)` event in response artifacts.
- No manual interaction required.
- Run remains serial and leaves no long-running `PushGoWatch` process.
