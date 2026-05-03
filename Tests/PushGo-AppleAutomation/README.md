# PushGo Apple Serial Automation Suite

## Scope

This suite is the serial execution entrypoint for Apple automation on constrained machines.
It enforces strict one-system-at-a-time execution to reduce CPU and memory pressure.

## Pipeline (Serial Only)

1. `PushGoAppleCoreTests` (`swift test`)
2. `PushGo-macOSUITests`
3. `PushGo-macOSAutomation` smoke script
4. `PushGo-watchOSAutomation` smoke script
5. `PushGo-iOSUITests` (`build-for-testing` + `test-without-building`)

Every stage writes logs to `/tmp/pushgo-apple-automation-logs`.

## Run Command

```bash
/Users/ethan/Repo/PushGo/pushgo/Tests/PushGo-AppleAutomation/run_apple_automation_serial.sh
```

## Optional Flags

- `RUN_CORE_TESTS=0` skip white-box package tests
- `RUN_MACOS_UI=0` skip macOS UI tests
- `RUN_MACOS_SMOKE=0` skip macOS command smoke tests
- `RUN_WATCHOS_SMOKE=0` skip watchOS smoke tests
- `RUN_IOS_UI=0` skip iOS UI tests
- `NO_INTERACTIVE_SIGNING=1` (default) use non-interactive signing flags to reduce password/2FA prompts
- `LOG_ROOT=/custom/path` override log output directory

Apple automation sessions also default to `PUSHGO_AUTOMATION_ALLOW_CROSS_APP_DATA_ACCESS=0` to suppress clipboard/system cross-app permission prompts during unattended runs.  
Set `PUSHGO_AUTOMATION_ALLOW_CROSS_APP_DATA_ACCESS=1` only when validating copy/open-external integrations.

## Pass Criteria

- Every enabled stage exits with status `ok`.
- No parallel app-system execution is used.
- watchOS/iOS simulator stages are cleaned up between runs.
