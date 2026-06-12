# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and this project follows [Semantic Versioning](https://semver.org/).

PushGo policy:
- Release tags use `vX.Y.Z`.
- Beta tags use `vX.Y.Z-beta.N`, and `N` maps to the beta build number for that version line.
- Build numbers are managed through tag progression; release packaging scripts do not calculate build numbers.
- Beta work accumulates in `[Unreleased]`; only formal releases get frozen version sections.

## [Unreleased]


## [v1.2.6] - 2026-06-12

### Changed
- Finalized Apple release display version to `v1.2.6` across release targets.
- Bumped Apple build number for release packaging (`CURRENT_PROJECT_VERSION: 82 -> 83`).
- Added versioned release note source file: `release/update-notes/v1.2.6.json`.
- Normalized newly generated Apple localization keys to snake_case identifiers.

### Fixed
- Fixed iOS message detail text selection crashes caused by the rich-text selection path.
- Fixed macOS message detail text selection so selectable title and body text work consistently.
- Preserved markdown rendering for selectable message bodies by routing selectable detail text through native SwiftUI text selection.
- Updated the Textual dependency pin to the cleaned-up selection hardening commit.

## [v1.2.5] - 2026-06-09

### Changed
- Finalized Apple release display version to `v1.2.5` across release targets.
- Bumped Apple build number by `+1` for release packaging (`CURRENT_PROJECT_VERSION: 80 -> 81`).
- Added versioned release note source file: `release/update-notes/v1.2.5.json`.
- Lowered Apple deployment targets to `iOS 17.0`, `macOS 14.0`, and `watchOS 10.0`.

### Improved
- Added customizable notification sounds across Apple apps with shared settings, preview, and delivery-state handling.
- Improved entity, event, and message projection behavior after patch application and notification-driven refreshes.
- Improved message-list refresh behavior during pending deletion and mark-all-read flows so visible state stays in sync more reliably.
- Polished macOS custom presentation focus styling, message titles, sidebar toolbar behavior, and settings interactions.

### Fixed
- Fixed iOS 17 and watchOS state-sync regressions that surfaced during Apple deployment-target downleveling.
- Fixed entity patch merge edge cases that could leave object or event details out of date after local updates.

## [v1.2.4] - 2026-05-26

### Changed
- Finalized Apple release display version to `v1.2.4` across release targets.
- Bumped Apple build number by `+1` for release packaging (`CURRENT_PROJECT_VERSION: 78 -> 79`).
- Added versioned release note source file: `release/update-notes/v1.2.4.json`.
- Updated release notes baseline with a dedicated `v1.2.4` section in `release/RELEASE_NOTES.md`.

### Improved
- Shared Apple app controllers across iOS and macOS to reduce behavior drift in channel sync, provider route updates, and notification ingress flows.
- Refactored toast and feedback presentation policy for clearer and more consistent validation and status messaging across settings, search, and management screens.
- Improved list-level interaction consistency for message, event, and thing surfaces across Apple clients.

### Fixed
- Fixed Apple strict-concurrency audit gate failure by removing a stale unsafe-pointer allowlist entry after runtime diagnostics moved out of `RootView`.
- Stabilized local index retry test behavior in Apple CI runtime-quality coverage.

## [v1.2.3] - 2026-05-16

### Changed
- Persisted unread-only message filter state across message list sessions.
- Added App Store metadata generation for release submissions, including localized support URLs.
- Expanded Apple runtime quality automation and localized fixture coverage across iOS, macOS, and watchOS.

### Improved
- Improved rich message detail rendering performance for large markdown payloads.
- Improved message filtering behavior with large tag sets and richer runtime fixtures.
- Improved notification-open handling so tapped notifications show detail content before deferred read-state refresh.

### Fixed
- Fixed channel subscription list identity and duplicate subscription handling to prevent list instability.
- Rejected blank channel subscription identifiers before they can enter subscription state.
- Hardened local metadata indexes, tag filtering, and legacy data rebuild paths.

## [v1.2.2] - 2026-05-11

### Changed
- Added tag-aware message search and coordinated pending local deletion state handling.
- Added multi-select facets and tag-count-backed filtering for message, event, and object lists.
- Unified destructive actions on Apple platforms with undoable local deletion flows.

### Improved
- Improved notification ingress recovery and delivery continuity across iOS, macOS, and watchOS.
- Improved global error UX consistency, including shared validation and toast/error presentation behavior.
- Improved app state controller structure and automation coverage for more stable Apple cross-surface behavior.

## [v1.2.1] - 2026-04-24

### Changed
- Finalized Apple release display version to `v1.2.1` across release targets.
- Bumped Apple build number by `+1` for release packaging (`CURRENT_PROJECT_VERSION: 75 -> 76`).
- Added versioned release note source file: `release/update-notes/v1.2.1.json`.

### Improved
- Improved overall reliability and behavior consistency across iOS, macOS, and watchOS.
- Improved markdown and remote image rendering stability in shared Apple UI surfaces.

## [v1.2.0] - 2026-04-20

### Changed
- Finalized Apple release display version to `v1.2.0` across release targets.
- Bumped Apple build number by `+1` for release packaging (`CURRENT_PROJECT_VERSION: 72 -> 73`).
- Added versioned release note source file: `release/update-notes/v1.2.0.json`.

### Fixed
- Reduced delayed provider pull windows after token refresh by triggering ingress sync immediately.
