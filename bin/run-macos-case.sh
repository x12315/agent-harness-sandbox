#!/usr/bin/env bash
# Compatibility entry point for existing macOS Tart callers.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
exec bash "$ROOT/bin/run-tart-case.sh" "$@"
