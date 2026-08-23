# Apple and Gateway 1.3.0 release

## Scope

- Publish Apple 1.3.0 as build 90 with signed App Store artifacts and a notarized macOS DMG.
- Publish Gateway 1.3.0 with the same Linux-only target matrix as 1.2.x.
- Keep production Gateway validation outside the blocking gate; use the synthetic rollback database instead.

## Released signing contract

- The macOS App Store widget uses `io.ethan.pushgo.macwidgets`, as required by App Store validation.
- The independently distributed DMG overrides only that target to `io.ethan.pushgo.widgets.mac`, matching its Developer ID profile.
- Stable App Store retries reuse an existing platform build and update metadata without uploading the same binary again.

## Completion evidence

- Repository-native release gates pass on the final commit.
- Hosted signing, notarization, upload, artifact, tag, and release results are checked after delivery.
- Apple release workflow run `32635431049` passed all jobs; Gateway release workflow run `32629313057` passed.
- Apple `v1.3.0` resolves to `baaeeb60d261aaed01ec51569bb3da9df97320bf`; Gateway `v1.3.0` resolves to `204edd7cd29c234309e24930b76e60615e7c2e6d`.
