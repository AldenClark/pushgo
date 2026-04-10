# Release Notes

This file contains end-user-facing release notes for App Store, TestFlight, and GitHub Releases.

Policy:
- Beta tags use `vX.Y.Z-beta.N`, and read from `[Unreleased]`.
- Release tags use `vX.Y.Z`, and read from `[vX.Y.Z]`.
- Keep entries user-visible and outcome-focused.
- Internal refactors, CI changes, and implementation details belong in `CHANGELOG.md`.

## [Unreleased]

### Improved
- Added built-in updater support for self-distributed macOS DMG builds using Sparkle 2.
- Added a "Enable beta updates" toggle next to "Check for Updates" in macOS Settings, with immediate background check when enabled.
- Automatic update checks now run silently in the background on a recurring schedule (every 6 hours by default) and notify when a new version is available.
- DMG release artifacts now use SemVer versioned filenames (for example, `PushGo-macOS-v1.2.0-beta.3.dmg`) for clearer distribution and rollback tracking.

### Fixed
- Reduced noisy update-check error prompts during automatic background checks when the network or update source is temporarily unavailable.
