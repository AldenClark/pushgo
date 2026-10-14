# PushGo for Apple Platforms

PushGo for Apple platforms (iOS/macOS/watchOS) is the official client app for PushGo. It works with PushGo Gateway to receive notifications on Apple devices.

## Project Links

- Apple platforms (this repo): https://github.com/AldenClark/pushgo
- Gateway: https://github.com/AldenClark/pushgo-gateway
- Android app: https://github.com/AldenClark/pushgo-android

## Download

- **App Store** - https://apps.apple.com/cn/app/pushgo/id6757907675
- **Testflight** -  https://testflight.apple.com/join/xhYmNZH8

## Requirements

- iOS 17+
- macOS 14+
- watchOS 10+

This client source requires Gateway V2 Pull and explicit ACK (`/v2/messages/pull` and `/v2/messages/ack`). Upgrade Gateway before upgrading the app. The earliest verified local stable tag with both endpoints is Gateway `v1.3.0`; the inspected `v1.2.10` and `v1.3.0-beta.1` tags do not provide these endpoints. New requests never fall back to destructive legacy Pull. Previously fetched local ingress remains recoverable until successfully stored.

This protocol minimum is not a complete compatibility claim for every current feature. The Watch reminder-window fields additionally require the Gateway implementation in commit `0c0365ef`; that commit has no matching local release tag, and the Cargo `1.3.3` declaration is not proof of a published compatible release.

## Testing

- Apple Core/Store tests: `./scripts/run_apple_core_tests.sh` (builds the test-only migration child before `swift test`). For a bare `swift test`, first run `swift build --product PushGoSQLiteMigrationChild`.
- Concurrency + build gate: `./scripts/apple_concurrency_gate.sh`
- iOS UI tests (stable runner flow with simulator preboot + retry):
  - Full suite: `./scripts/run_ios_ui_tests.sh`
  - Single test: `TEST_SCOPE='PushGo-iOSUITests/PushGo_iOSUITests/testLaunchesIntoMessageList' ./scripts/run_ios_ui_tests.sh`


# PushGo Apple 平台

PushGo Apple 平台（iOS/macOS/watchOS）是 PushGo 的官方客户端应用，可配合 PushGo Gateway 在 Apple 设备上接收通知。

## 项目链接

- Apple 平台（本仓库）：https://github.com/AldenClark/pushgo
- 网关：https://github.com/AldenClark/pushgo-gateway
- Android App：https://github.com/AldenClark/pushgo-android

## 下载地址

- **App Store** - https://apps.apple.com/cn/app/pushgo/id6757907675
- **Testflight** -  https://testflight.apple.com/join/xhYmNZH8

## 环境要求

- iOS 17+
- macOS 14+
- watchOS 10+

本源码要求 Gateway 支持 V2 Pull 和显式 ACK（`/v2/messages/pull`、`/v2/messages/ack`）。请先升级 Gateway，再升级 App。经核对，最早同时包含两路由的本地正式标签是 Gateway `v1.3.0`；已检查的 `v1.2.10`、`v1.3.0-beta.1` 标签没有这两路由。新请求不再回退到破坏性旧 Pull，升级前已取回的本地入站内容继续保留并结清。

上述是协议下限，不代表当前所有功能均兼容。Watch 提醒窗口字段另需 Gateway 提交 `0c0365ef` 中的实现；本地尚无包含该提交的发布标签，Cargo 声明 `1.3.3` 不能作为已发布兼容版本的证明。

## 测试

- Apple Core/Store 测试：`./scripts/run_apple_core_tests.sh`（在 `swift test` 前构建仅供测试的迁移子进程程序）。直接运行裸 `swift test` 前，先执行 `swift build --product PushGoSQLiteMigrationChild`。
- 并发/构建闸门：`./scripts/apple_concurrency_gate.sh`
- iOS UI 测试（稳定执行：模拟器预热 + runner 启动重试）：
  - 全量：`./scripts/run_ios_ui_tests.sh`
  - 单测：`TEST_SCOPE='PushGo-iOSUITests/PushGo_iOSUITests/testLaunchesIntoMessageList' ./scripts/run_ios_ui_tests.sh`
