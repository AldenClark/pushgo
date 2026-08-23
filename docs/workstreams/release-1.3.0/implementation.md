# Apple and Gateway 1.3.0 release

## Scope

- Publish Apple 1.3.0 as build 90 with signed App Store artifacts and a notarized macOS DMG.
- Publish Gateway 1.3.0 with the same Linux-only target matrix as 1.2.x.
- Keep production Gateway validation outside the blocking gate; use the synthetic rollback database instead.

## Current release recovery

- The macOS App Store widget uses `io.ethan.pushgo.macwidgets`, as required by App Store validation.
- The independently distributed DMG overrides only that target to `io.ethan.pushgo.widgets.mac`, matching its Developer ID profile.
- Stable App Store retries reuse an existing platform build and update metadata without uploading the same binary again.

## Completion evidence

- Repository-native release gates pass on the final commit.
- Hosted signing, notarization, upload, artifact, tag, and release results are checked after delivery.
