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
- Apple release automation now supports SemVer tag strategy (`vX.Y.Z` and `vX.Y.Z-beta.N`) and derives release kind directly from tags.
- Root-level changelog governance is introduced, and release notes extraction is wired to `CHANGELOG.md`.

### Changed
- Apple release workflow now reads release notes from `CHANGELOG.md`:
  - beta uses `[Unreleased]`
  - release uses `[vX.Y.Z]`
- GitHub Release body generation for Apple artifacts now uses changelog sections from `CHANGELOG.md` instead of ad-hoc commit log text.
- DMG packaging/signing pipeline remains cloud-signing + notarization and is aligned with explicit team/signing parameters.
- Apple concurrency gate and related scripts were updated for CI robustness and signing/provisioning behavior.
- iOS UI screens and localization assets were updated across event list, main tab, settings, and string resources.
- Xcode project settings and workspace metadata were updated for current build/signing workflow behavior.

### Fixed
- Fixed release lane path handling for project/output resolution under CI.
- Fixed stale App Store export method usage by migrating to modern `app-store-connect` export method naming.
- Fixed Apple UI automation stability issues by aligning fixture projection semantics and replacing brittle iOS UI test assertions with state/event-based checks.
- Fixed `PushGo-iOSUITests` runner retry behavior to avoid false transient retries triggered by non-fatal `IDELaunchParametersSnapshot` logs.
