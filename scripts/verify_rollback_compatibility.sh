#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

(
  cd "$ROOT"
  swift test \
    --disable-automatic-resolution \
    --filter 'nWriterRollbackShadowsDecode|rollbackShadowWriteFailure|nMinusOneV2AckShadow'
)

echo "N-to-N-1 rollback compatibility and failure observability verified"
