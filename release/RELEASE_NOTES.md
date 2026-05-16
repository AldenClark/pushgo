# Release Notes

This file contains end-user-facing release notes for App Store, TestFlight, and GitHub Releases.

Policy:
- Beta tags use `vX.Y.Z-beta.N`, and read from `[Unreleased]`.
- Release tags use `vX.Y.Z`, and read from `[vX.Y.Z]`.
- Keep entries user-visible and outcome-focused.
- Internal refactors, CI changes, and implementation details belong in `CHANGELOG.md`.

## [Unreleased]


## [v1.2.3]

### Improved
- The unread-only message filter now stays active when returning to the message list.
- Channel subscription lists are more stable and reject blank or duplicate subscription identifiers.
- Large rich-text and markdown message details render more smoothly.
- Notification taps open message details more reliably before read-state refresh finishes.
- Filtering remains usable with larger tag sets and heavier local message data.

## [v1.2.2]

### Improved
- Added tag-aware message search and multi-select facet filters with tag counts.
- Improved list filtering and discovery across messages, events, and objects.
- Unified delete/close destructive actions with undoable local deletion behavior.
- Improved error feedback consistency across iOS, macOS, and watchOS.
- Hardened notification ingress recovery and watch delivery reliability.

## [v1.2.1]

### Improved
- Includes all Apple-side updates accumulated after `v1.2.0`.
- Improved overall reliability and behavior consistency across iOS, macOS, and watchOS.
- Improved markdown and remote image rendering stability in shared Apple UI surfaces.

## [v1.2.0]

### Improved
- Improved ACK + pull reliability after provider token refresh by triggering ingress sync immediately.
- Improved delivery continuity on iOS and macOS when provider route bindings refresh.

### Fixed
- Fixed a timing gap where provider pull could lag behind token updates.
