# Release Notes

This file contains end-user-facing release notes for App Store, TestFlight, and GitHub Releases.

Policy:
- Beta tags use `vX.Y.Z-beta.N`, and read from `[Unreleased]`.
- Release tags use `vX.Y.Z`, and read from `[vX.Y.Z]`.
- Keep entries user-visible and outcome-focused.
- Internal refactors, CI changes, and implementation details belong in `CHANGELOG.md`.

## [Unreleased]

### Improved
- Added widgets, controls, search indexing, and app shortcuts so important messages, events, and objects are easier to reach from Apple system surfaces.
- Added WidgetKit push wiring so widget and complication snapshots stay fresher across iPhone, Mac, and Apple Watch.
- Reworked the Apple Watch receiver flow so delivery, sync state, and receiver-health reporting behave more independently and predictably.
- Improved cached image handling and refreshed Apple localization assets after the current integration pass.

## [v1.2.7]

### Improved
- Improved message detail rendering reliability across iPhone, Mac, and Apple Watch.
- iPhone and Mac now keep selectable message titles while using platform-specific markdown body rendering.
- Apple Watch message notifications and details now use a lightweight plain-text body path for steadier display.
- Refreshed Apple localization catalogs after the markdown rendering update.

## [v1.2.6]

### Fixed
- Fixed message detail text selection on iOS and macOS so titles and markdown bodies can be selected without crashes.
- Markdown message bodies now keep markdown rendering while using stable native text selection.
- Cleaned up Apple localization string keys to reduce string-catalog warnings.

## [v1.2.5]

### Improved
- Added customizable notification sounds across iPhone, Mac, and Apple Watch.
- Message lists now refresh more reliably during mark-all-read and pending deletion flows.
- Event, message, and object details stay more accurate after patch and notification updates.
- Expanded Apple compatibility to iOS 17, macOS 14, and watchOS 10, with additional macOS presentation polish.

## [v1.2.4]

### Improved
- Improved cross-platform interaction consistency for message, event, and thing lists between iOS and macOS.
- Improved toast and inline feedback clarity across settings, search, and management surfaces.
- Shared app controllers now reduce iOS/macOS behavior drift in channel sync and notification ingress flows.
- Improved local data and automation runtime stability under retry and larger-state conditions.

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
