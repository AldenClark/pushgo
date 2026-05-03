# PushGo macOS Automation Matrix

## Scope

This smoke suite validates command/response/state automation flows on macOS.
It is designed as a stable complement to `PushGo-macOSUITests`.

## Coverage Matrix

| Case | Coverage |
| --- | --- |
| `nav_channels` | startup command `nav.switch_tab` routes to `screen.channels` |
| `hide_events_page` | settings boundary command `settings.set_page_visibility` toggles `event_page_enabled=false` |
| `show_events_page` | settings boundary round-trip toggles `event_page_enabled=true` |
| `set_decryption_key_base64` | decryption key success path (`notification_key_configured=true`, `notification_key_encoding=base64`) |
| `set_decryption_key_invalid` | invalid key path returns `ok=false` and key validation error |
| `fixture_import_event` | fixture import command path validates event ingestion (`event_count >= 1`) |
| `entity_open_event` | shared-runtime fixture + `entity.open` validates detail screen state and `entity.opened(entity_id=target)` event |
| `entity_open_thing` | shared-runtime fixture + `entity.open` validates thing detail state and target `entity.opened` event |

## Run Command

```bash
/Users/ethan/Repo/PushGo/pushgo/Tests/PushGo-macOSAutomation/macos_automation_smoke.sh
```

The script defaults to non-interactive signing mode (`NO_INTERACTIVE_SIGNING=1`) to reduce system password/2FA prompts.
Automation runtime defaults to `PUSHGO_AUTOMATION_ALLOW_CROSS_APP_DATA_ACCESS=0` so smoke runs are not blocked by clipboard/system cross-app permission alerts.
Smoke cases are executed through the app's built-in startup automation protocol (`PUSHGO_AUTOMATION_REQUEST` + response/state/events files), without external helper scripts.
Fixture defaults now point to `pushgo/Tests/Fixtures/p2` inside this repository.

## Pass Criteria

- All smoke cases complete successfully.
- All command cases produce valid response and state payloads.
- Every `ok=true` case also satisfies `runtime_error_count == 0` and `local_store_mode != unavailable`.
- `entity.open` cases must observe a matching `entity.opened` event for the requested entity id.
- No manual interaction required.
