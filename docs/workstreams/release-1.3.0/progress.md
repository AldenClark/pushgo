# Apple and Gateway 1.3.0 release progress

## Completed

- Gateway 1.3.0 is published with six Linux binaries: amd64, arm64, and armv7 for GNU and musl.
- Gateway synthetic upgrade and rollback validation passed; production validation was intentionally not run.
- Apple 1.3.0 build 90 release gate passed, iOS uploaded, and the notarized DMG was published.

## Current

- The App Store/direct-distribution identifier split is implemented and locally verified.
- Prepare the corrected source commit and move the 1.3.0 tag to it.

## Next

- Push the corrected tag and verify hosted signing, App Store upload, notarization, and release results.

## Evidence limits

- Codex Security Deep Scan is waived by user instruction.
- Physical-device and production Gateway validation are not blocking release gates.
