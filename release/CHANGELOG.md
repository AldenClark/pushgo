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
- Bumped Apple release line to `v1.2.3-beta.2`.
- Bumped Apple build number by `+1` (`CURRENT_PROJECT_VERSION: 60 -> 61`) across release targets.
- Updated project marketing/display version wiring:
  - `MARKETING_VERSION = 1.2.3`
  - `PUSHGO_DISPLAY_VERSION = v1.2.3-beta.2`
- iOS/macOS token update flow now triggers provider ingress sync immediately after provider route sync.

### Fixed
- Reduced missed provider pull windows after token refresh by actively pulling ingress on `token_update`.
