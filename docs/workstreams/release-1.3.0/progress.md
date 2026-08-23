# Apple and Gateway 1.3.0 release progress

## Completed

- Gateway 1.3.0 is published with six Linux binaries: amd64, arm64, and armv7 for GNU and musl.
- Gateway synthetic upgrade and rollback validation passed; production validation was intentionally not run.
- Apple 1.3.0 build 90 release gate passed on release commit `baaeeb60d261aaed01ec51569bb3da9df97320bf`.
- The App Store job created or reused the macOS widget profile, signed both store artifacts, reused the existing iOS 1.3.0 (90) binary, updated its metadata, and uploaded the macOS package.
- The notarized and stapled DMG, SBOM, attestations, Sparkle appcast, update-host artifact, and GitHub release were published successfully.
- The final Apple workflow run `32635431049` completed all release-gate, DMG, and App Store jobs successfully.
- The published DMG is 22,334,893 bytes with SHA-256 `6e48c39bcc9744229d44edecc617bede5857c7368c812cbf6c1993cf37a263e2`; the stable update feed advertises the same artifact length.

## Current

- Apple and Gateway 1.3.0 are released.
- App Store Connect submission for review and automatic release remain intentionally disabled.

## Next

- Submit the Apple versions for review when product approval is given.
- Perform production Gateway smoke validation later when a suitable environment is available; this is not a release prerequisite.

## Evidence limits

- Codex Security Deep Scan is waived by user instruction.
- Physical-device and production Gateway validation were not run and are not blocking release gates.
- The final audit was performed in the same working context, so common-mode review risk remains; no independent reviewer was authorized.
