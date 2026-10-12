#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

# The cross-process Store recovery tests launch this test-only executable.
# SwiftPM does not build executable products just because swift test compiles
# their source, so build it before entering SwiftPM's test build lock.
swift build --package-path "$repo_root" \
  --disable-automatic-resolution \
  --jobs 2 \
  --product PushGoSQLiteMigrationChild

exec swift test --package-path "$repo_root" \
  --disable-automatic-resolution "$@"
