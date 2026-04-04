# PushGo for Apple Platforms

PushGo for Apple platforms (iOS/macOS/watchOS) is the official client app for PushGo. It works with PushGo Gateway to receive notifications on Apple devices.

## Project Links

- Apple platforms (this repo): https://github.com/AldenClark/pushgo
- Gateway: https://github.com/AldenClark/pushgo-gateway
- Android app: https://github.com/AldenClark/pushgo-android

## TestFlight (IMPORTANT)


https://testflight.apple.com/join/xhYmNZH8


## Requirements

- iOS 17+
- macOS 14+
- watchOS 10+

## CI Release

- Tag `Beta-*` uploads to TestFlight
- Tag `Release-*` uploads via App Store lane
- Setup guide: `docs/apple-release-ci.md`

# PushGo Apple 平台（中文）

PushGo Apple 平台（iOS/macOS/watchOS）是 PushGo 的官方客户端应用，可配合 PushGo Gateway 在 Apple 设备上接收通知。

## 项目链接

- Apple 平台（本仓库）：https://github.com/AldenClark/pushgo
- 网关：https://github.com/AldenClark/pushgo-gateway
- Android App：https://github.com/AldenClark/pushgo-android

## TestFlight（重要）

当前 iOS/macOS/watchOS App 处于 TestFlight 测试阶段。

测试入口：
https://testflight.apple.com/join/xhYmNZH8


## 环境要求

- iOS 17+
- macOS 14+
- watchOS 10+

## CI 发布

- `Beta-*` tag 触发 TestFlight 上传
- `Release-*` tag 触发 App Store 发布通道上传
- 配置说明见：`docs/apple-release-ci.md`
