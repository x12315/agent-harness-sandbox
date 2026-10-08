#!/usr/bin/env bash
set -euo pipefail
D=${1:?usage: assert.sh <run-dir>}
[ "$(cat "$D/guest/tmp/ah.rc")" = 0 ]
[ ! -s "$D/guest/tmp/ah.err" ]
[ -s "$D/gui.png" ]
grep -qx 'guestBrowserMode=headless PASS' "$D/guest/tmp/ah.out"
grep -qx 'guestBrowserMode=headed PASS' "$D/guest/tmp/ah.out"
grep -Eq '^guestBrowserWindows=[1-9][0-9]*$' "$D/guest/tmp/ah.out"
echo 'ok: guest browser CLI interacted in both modes and a headed Chrome window was observed'
