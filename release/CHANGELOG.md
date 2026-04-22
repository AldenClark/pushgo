# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and this project follows [Semantic Versioning](https://semver.org/).

PushGo policy:
- Release tags use `vX.Y.Z`.
- Beta tags use `vX.Y.Z-beta.N`, and `N` maps to the beta build number for that version line.
- Build numbers are managed through tag progression; release packaging scripts do not calculate build numbers.
- Beta work accumulates in `[Unreleased]`; only formal releases get frozen version sections.

## [Unreleased]

### Changed
- Bumped Apple marketing version to `1.3.0-beta.1`.
- Bumped Apple build number by `+1` (`CURRENT_PROJECT_VERSION: 74 -> 75`).
- Synced Apple display version to `v1.3.0-beta.1` across release targets.
- Added versioned update note source file: `release/update-notes/v1.3.0-beta.1.json`.

## [v1.2.0] - 2026-04-20

### Changed
- Finalized Apple release display version to `v1.2.0` across release targets.
- Bumped Apple build number by `+1` for release packaging (`CURRENT_PROJECT_VERSION: 72 -> 73`).
- Added versioned release note source file: `release/update-notes/v1.2.0.json`.

### Fixed
- Reduced delayed provider pull windows after token refresh by triggering ingress sync immediately.
