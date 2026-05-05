# PushGo macOS Automation Matrix

## Scope

This suite targets the macOS app runtime and validates end-to-end UI reachability across primary pages, startup automation commands, and key settings overlays.

## UI Coverage Matrix

| Test | Coverage |
| --- | --- |
| `testLaunchesIntoMessageList` | cold launch baseline (`screen.messages.list`) |
| `testSidebarNavigationCoversPrimaryScreens` | sidebar route coverage: events/things/channels/settings/messages |
| `testAutomationRequestCanOpenChannelsScreen` | startup automation request `nav.switch_tab` with channels page markers |
| `testImportedEventFixtureCanOpenEventDetailFromStartupRequest` | fixture import + event detail deep page reachability |
| `testImportedThingFixtureCanOpenThingDetailFromStartupRequest` | fixture import + thing detail deep page reachability |
| `testSettingsSidebarCanOpenDecryptionOverlay` | settings overlay flow (`screen.settings.decryption`) |
| `testSettingsScreenControlMatrixShowsCriticalGroups` | settings关键控件矩阵（server/page-visibility/decryption） |
| `testSettingsPageVisibilityCommandCanHideEventPage` | settings mutation command keeps sidebar/events route hidden |
| `testSettingsPageVisibilityCommandCanRoundTripEventPage` | settings开关前后态正确性（false -> true） |
| `testFixtureSeedEntityRecordsPublishesProjectionCounts` | 实体投影视图写入链路（`fixture.seed_entity_records`） |
| `testFixtureSeedSubscriptionsPublishesImportState` | 频道订阅写入链路（`fixture.seed_subscriptions`）与 import bookkeeping 状态 |
| `testEntityOpenPublishesEntityStateAndProjectionCounts` | entity.open正确性：状态命中detail页 + `entity.opened`事件包含目标`entity_id` |
| `testMessageOpenPublishesMessageDetailState` | message.open 路由到消息详情并发布 opened message state |
| `testNotificationOpenPublishesMessageDetailState` | notification.open 路由到消息详情 |
| `testNotificationMarkReadCommandUpdatesUnreadState` | `notification.mark_read` 更新未读计数与动作事件 |
| `testNotificationDeleteCommandUpdatesCounts` | `notification.delete` 删除消息并发布动作事件 |
| `testGatewaySetServerCommandUpdatesConfigurationState` | `gateway.set_server` 更新 server config 与 settings.changed 事件 |
| `testBaselineAutomationStateHasNoRuntimeErrors` | 启动基线正确性（`runtime_error_count == 0`） |

## White-Box Coverage

Run the Swift package core tests for semantics, storage, notification handling, and ACK logic:

- `PushGoAppleCoreTests` (68 tests)

Command-response smoke coverage for macOS automation handlers is maintained in:

- `/Users/ethan/Repo/PushGo/pushgo/Tests/PushGo-macOSAutomation/macos_automation_smoke.sh`

## Run Commands

```bash
xcodebuild -project /Users/ethan/Repo/PushGo/pushgo/pushgo.xcodeproj \
  -scheme PushGo-macOS \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/pushgo-macos-uitests-complete \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  test -only-testing:PushGo-macOSUITests
```

```bash
swift test --package-path /Users/ethan/Repo/PushGo/pushgo --filter PushGoAppleCoreTests
```

Serial full Apple pipeline entry:

```bash
/Users/ethan/Repo/PushGo/pushgo/Tests/PushGo-AppleAutomation/run_apple_automation_serial.sh
```

## Pass Criteria

- `PushGo-macOSUITests`: all tests pass with zero failures.
- `PushGoAppleCoreTests`: all suites pass (no skipped failures).
- No manual interaction required during runs.
- UI控件矩阵、automation状态字段与 `events.jsonl` 语义事件都必须满足断言。

By default, UI test launches set `PUSHGO_AUTOMATION_ALLOW_CROSS_APP_DATA_ACCESS=0` to avoid blocking prompts such as “PushGo wants to access data from other apps”.
macOS UI runner requires a normal local development signature; forcing `CODE_SIGNING_ALLOWED=NO` causes the runner to exit before establishing the XCTest connection.
