# PushGo iOS Automation Matrix

## Scope

This suite validates iOS startup automation, deep-page navigation, tab routing, and settings mutation commands.

## UI Coverage Matrix

| Test | Coverage |
| --- | --- |
| `testLaunchesIntoMessageList` | cold launch baseline (`screen.messages.list`) |
| `testAutomationRequestCanOpenChannelsScreen` | startup command `nav.switch_tab` + channels page markers |
| `testNavSwitchTabMatrixCoversPrimaryScreens` | command-routed tab matrix: messages/events/things/channels |
| `testImportedEventFixtureCanOpenEventDetail` | fixture import + event detail deep page |
| `testImportedThingFixtureCanOpenThingDetail` | fixture import + thing detail deep page |
| `testPushSettingsCanOpenDecryptionScreen` | settings decryption overlay command flow |
| `testFixtureSeedMessagesRefreshesMessageList` | 消息写入后列表刷新链路（`fixture.seed_messages`） |
| `testSettingsPageVisibilityCommandCanHideEventPage` | settings mutation boundary (`event_page_enabled=false`) |
| `testSettingsPageVisibilityCommandCanRoundTripEventPage` | settings开关前后态正确性（false -> true） |
| `testSettingsSetDecryptionKeyRejectsInvalidLength` | invalid decryption key boundary (`ok=false`, `invalid key`) |
| `testSettingsSetDecryptionKeyAcceptsBase64Key` | decryption key success path (`notification_key_configured=true`, `notification_key_encoding=base64`) |
| `testEntityOpenPublishesEntityStateAndProjectionCounts` | entity.open正确性：状态命中detail页 + `entity.opened`事件包含目标`entity_id` |
| `testBaselineAutomationStateHasNoRuntimeErrors` | 启动基线正确性（`runtime_error_count == 0`） |

## Run Command

```bash
xcodebuild -project /Users/ethan/Repo/PushGo/pushgo/pushgo.xcodeproj \
  -scheme PushGo-iOS \
  -destination 'platform=iOS Simulator,name=iPhone Air,OS=26.2' \
  -derivedDataPath /tmp/pushgo-ios-uitests-complete \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  EXCLUDED_ARCHS__EFFECTIVE_PLATFORM_SUFFIX_iphonesimulator=x86_64 \
  EXCLUDED_ARCHS__EFFECTIVE_PLATFORM_SUFFIX_watchsimulator=x86_64 \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= \
  test -only-testing:PushGo-iOSUITests
```

Serial full Apple pipeline entry:

```bash
/Users/ethan/Repo/PushGo/pushgo/Tests/PushGo-AppleAutomation/run_apple_automation_serial.sh
```

## Pass Criteria

- `PushGo-iOSUITests`: all tests pass with zero failures.
- No manual interaction required during run.
- Command response/state + `events.jsonl` + UI identifiers all satisfy assertions (not only page reachability).

UI test launches set `PUSHGO_AUTOMATION_ALLOW_CROSS_APP_DATA_ACCESS=0` to keep unattended runs clear of pasteboard-related cross-app prompts.
