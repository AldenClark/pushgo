# Apple Release CI (Tag Driven)

This repository supports tag-driven Apple release automation:

- `Beta-*` tag: build + upload to TestFlight
- `Release-*` tag: build + upload to App Store Connect (App Store lane)

Workflow file: `.github/workflows/apple-release.yml`

## Required GitHub Secrets

- `ASC_KEY_ID`: App Store Connect API Key ID
- `ASC_ISSUER_ID`: App Store Connect Issuer ID
- `ASC_KEY_P8`: API key content (`.p8` file body)

## Optional GitHub Variables

- `ASC_KEY_IS_BASE64`: set `true` only if `ASC_KEY_P8` is stored in base64 format
- `APP_STORE_SUBMIT_FOR_REVIEW`: `true` to auto-submit review in release lane
- `APP_STORE_AUTOMATIC_RELEASE`: `true` to auto-release after approval in release lane

## Expected Project Defaults

- Xcode project: `pushgo.xcodeproj`
- Scheme: `PushGo-iOS`
- Bundle id: `io.ethan.pushgo`
- Signing: Automatic signing enabled in Xcode project

If you need a different scheme or bundle id, update env values in the workflow.

## Trigger Examples

```bash
# TestFlight
git tag Beta-1.1.3
git push origin Beta-1.1.3

# App Store lane
git tag Release-1.1.3
git push origin Release-1.1.3
```
