# Release Notes

This file contains end-user-facing release notes for App Store, TestFlight, and GitHub Releases.

Policy:
- Beta tags use `vX.Y.Z-beta.N`, and read from `[Unreleased]`.
- Release tags use `vX.Y.Z`, and read from `[vX.Y.Z]`.
- Keep entries user-visible and outcome-focused.
- Internal refactors, CI changes, and implementation details belong in `CHANGELOG.md`.

## [Unreleased]

### Improved
- Improved ACK + pull reliability after provider token refresh by triggering ingress sync immediately.
- Improved delivery continuity on iOS and macOS when the app refreshes provider route bindings.
- Updated this beta line to `v1.2.0-beta.8` with build number incremented.

### Fixed
- Fixed a timing gap where provider pull could lag behind token updates.
