# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and this project follows [Semantic Versioning](https://semver.org/).

PushGo policy:
- Release tags use `vX.Y.Z`.
- Beta tags use `vX.Y.Z-beta.N`, and `N` maps to the beta build number for that version line.
- Build numbers are managed through tag progression; release packaging scripts do not calculate build numbers.
- Beta work accumulates in `[Unreleased]`; only formal releases get frozen version sections.

## [Unreleased]

### Added
- Added Sparkle 2 based self-update flow for self-distributed macOS DMG builds, isolated behind dedicated `PushGo-macOS-DMG` target/scheme.
- Added `AppUpdateManager` integration for manual checks, automatic background probes, and beta channel routing (`sparkle:channel=beta`).
- Added a beta-channel toggle in macOS Settings next to "Check for Updates"; enabling beta immediately triggers a background update probe.
- Added `scripts/release_appcast.sh` for stable/beta appcast generation with signature and channel validation.

### Changed
- Apple release workflow now supports SemVer-driven DMG naming and emits versioned artifacts like `PushGo-macOS-v1.2.0-beta.3.dmg`.
- Sparkle scheduled check interval is now explicitly configured (default 21600 seconds / 6 hours) for DMG distribution builds.
- DMG Sparkle runtime config is now injected through dedicated xcconfig inputs for feed URL and check interval while keeping public EdDSA key in project build settings.
- Release notes extraction remains aligned to release tags (`vX.Y.Z`) and beta tags (`vX.Y.Z-beta.N`) via the `[Unreleased]` section.

### Fixed
- Fixed automatic background update checks to run in probe mode so transient update-fetch failures are silently skipped without surfacing user-facing errors.
- Fixed appcast generation output handling to consistently produce `appcast.xml` at the expected destination path.
