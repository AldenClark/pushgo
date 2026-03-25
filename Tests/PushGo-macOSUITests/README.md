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
| `testEntityOpenPublishesEntityStateAndProjectionCounts` | entity.open正确性：状态命中detail页 + `entity.opened`事件包含目标`entity_id` |
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
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= \
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
