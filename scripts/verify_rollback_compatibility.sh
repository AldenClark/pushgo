#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

(
  cd "$ROOT"
  "$ROOT/scripts/run_apple_core_tests.sh" \
    --filter 'nWriterRollbackShadowsDecode|rollbackShadowWriteFailure|nMinusOneV2AckShadow'
)

echo "N-to-N-1 rollback compatibility and failure observability verified"
