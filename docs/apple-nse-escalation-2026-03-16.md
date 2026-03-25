# PushGo macOS Notification Service Extension Failure (Escalation Packet)

Prepared on: 2026-03-16  
Prepared for: Apple Feedback Assistant / Apple Developer Technical Support (DTS)

## 1) Executive Summary

Our macOS Notification Service Extension (NSE) is launched by the system but fails before request handling completes.  
The failure is reproducible on this machine and blocks message ingestion while the app is not foregrounded.

Observed pattern:

- `usernoted` starts extension request/context setup.
- ~1.8 to 1.9 seconds later, system kills the extension with:
  - `Extension will be killed due to sluggish startup`
  - `Unable to setup extension context`
  - `NSCocoaErrorDomain Code=4099 ... apple-extension-service was invalidated`
- App-level NSE business logs never appear (`notification.ingest.apple.nse`), and message is not persisted to local DB.

## 2) Environment

- Hardware: MacBookAir10,1 (Apple M1, 16GB)
- OS: macOS 26.3.1 (Build 25D2128)
- Kernel: Darwin 25.3.0
- Xcode: 26.3 (17C529)
- App location: `/Applications/PushGo.app`
- Extension bundle id: `io.ethan.pushgo.NotificationServiceExtension`
- App bundle id: `io.ethan.pushgo`

## 3) User Impact

- Background receive path on macOS is broken because NSE cannot finish startup/handshake.
- Foreground app path can work, but background/private wakeup ingestion path does not.

## 4) Reproduction (Current)

1. Build and install app to `/Applications/PushGo.app`.
2. Launch app once (ensures PlugInKit registration), then quit app.
3. Send push message to subscribed channel (gateway sandbox).
4. Observe unified logs for `usernoted`, `runningboardd`, and extension process.

Result:

- Extension is spawned repeatedly and terminated during startup/context phase.

## 5) Key Log Evidence

Representative timeline (multiple runs show same behavior):

- `begin async extension request ... item count 0`
- `Making extension context and XPC connection ...`
- `Extension will be killed due to sluggish startup`
- `termination reported by launchd (2, 9, 9)`
- `Unable to setup extension context - error: ...`

Key local evidence files:

- `/tmp/pushgo-nse-cacheclean-20260316-185345-key.log`
- `/tmp/pushgo-nse-cacheclean-20260316-185345.log`
- `/tmp/pushgo-nse-nocov3-20260316-185151-key.log`

## 6) What We Already Ruled Out

We performed controlled checks and still reproduced the same failure:

1. Entitlements and signing
- Verified app + extension signatures and provisioning profiles.
- `aps-environment=development` present for app and extension.
- Same team id and app group are present.

2. Extension startup workload hypothesis (code-level)
- Added lazy initialization for processor in NSE entry path (no change).
- Disabled code coverage instrumentation for Release build (no change).

3. PlugInKit registration/cache hygiene
- Removed stale duplicate registrations and kept only `/Applications` registration.
- Failure still reproduces with same startup kill sequence.

4. App installation path
- If app is copied but never launched, we can get `Failed to find extension inside /Applications/PushGo.app`.
- After normal launch/quit (registration fixed), startup-kill issue still persists.

## 7) Additional Context

- User reports the same issue occurs even with a clean Xcode NSE template on this machine (same environment family).
- iOS NSE path is normal for the same product.

## 8) Request To Apple

Please help determine why `usernoted`/ExtensionKit context setup for macOS Notification Service Extension consistently times out and invalidates XPC connection on this environment.

Specific asks:

1. Is this a known issue/regression for this OS/Xcode combination?
2. Is there a platform constraint for this push shape/path on macOS that differs from iOS?
3. Which additional diagnostics should we capture to identify exact termination reason in host-side extension startup path?

## 9) Attachments Checklist For Submission

Please attach the following:

1. Unified logs (time-windowed around one reproduction)
2. `sysdiagnose` collected immediately after reproduction
3. App + extension signed entitlement dumps
4. Provisioning profile entitlements (app and extension)
5. Repro payload example (with secrets redacted)

Suggested commands:

```bash
# 1) Targeted unified logs
log show --last 20m --style compact \
  --predicate '(process == "usernoted") OR (process == "runningboardd") OR (process == "NotificationServiceExtension")' \
  > ~/Desktop/nse-log-window.txt

# 2) Entitlements
codesign -d --entitlements - /Applications/PushGo.app > ~/Desktop/pushgo-app-entitlements.txt
codesign -d --entitlements - /Applications/PushGo.app/Contents/PlugIns/NotificationServiceExtension.appex \
  > ~/Desktop/pushgo-nse-entitlements.txt

# 3) Provisioning profiles (decode)
security cms -D -i /Applications/PushGo.app/Contents/embedded.provisionprofile \
  > ~/Desktop/pushgo-app-profile.plist
security cms -D -i /Applications/PushGo.app/Contents/PlugIns/NotificationServiceExtension.appex/Contents/embedded.provisionprofile \
  > ~/Desktop/pushgo-nse-profile.plist
```

For sysdiagnose and diagnostics profiles, use Apple official instructions/pages:

- https://developer.apple.com/bug-reporting/
- https://developer.apple.com/bug-reporting/profiles-and-logs/?platform=macos

## 10) Suggested Submission Targets

- Primary: Feedback Assistant (attach full evidence bundle)
- Parallel: DTS technical support incident (for direct engineering guidance on extension host diagnostics)

---

## Appendix A: One-Line Problem Statement (for ticket title/body)

`macOS Notification Service Extension is launched but consistently killed by usernoted as "sluggish startup" during extension context setup (Code=4099 invalidated XPC service), preventing background message ingestion.`

