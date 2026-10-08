#!/usr/bin/env bash
set -euo pipefail
D=${1:?usage: assert.sh <run-dir>}
[ "$(cat "$D/guest/tmp/ah.rc")" = 0 ]
grep -q '^BROWSER_DEBUG_PASS$' "$D/guest/tmp/ah.out"
[ "$(cat "$D/guest/tmp/ah-artifacts/browser-debug/mode.txt")" = headless ]
node "$TESTBED/bin/browser-debug/assert-evidence.mjs" "$D/guest/tmp/ah-artifacts/browser-debug"
