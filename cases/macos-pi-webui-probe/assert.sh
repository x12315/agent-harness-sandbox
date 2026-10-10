#!/usr/bin/env bash
set -euo pipefail
D=${1:?usage: assert.sh <run-dir>}

[ "$(cat "$D/guest/tmp/ah.rc")" = 0 ]
rg '^node=v[0-9]+' "$D/guest/tmp/ah.out" >/dev/null
echo 'ok: macOS clone reported Node and WebUI/browser availability'
