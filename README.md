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

- iOS 18+
- macOS 15+
- watchOS 11+

## Testing

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

- iOS 18+
- macOS 15+
- watchOS 11+

## 测试

- 并发/构建闸门：`./scripts/apple_concurrency_gate.sh`
- iOS UI 测试（稳定执行：模拟器预热 + runner 启动重试）：
  - 全量：`./scripts/run_ios_ui_tests.sh`
  - 单测：`TEST_SCOPE='PushGo-iOSUITests/PushGo_iOSUITests/testLaunchesIntoMessageList' ./scripts/run_ios_ui_tests.sh`
