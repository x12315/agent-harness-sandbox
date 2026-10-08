#!/usr/bin/env bash
set -euo pipefail
D=${1:?usage: assert.sh <run-dir>}
[ "$(cat "$D/guest/tmp/ah.rc")" = 0 ]
[ ! -s "$D/guest/tmp/ah.err" ]
[ -s "$D/gui.png" ]
grep -Eq '^guestITermWindows=[1-9][0-9]*$' "$D/guest/tmp/ah.out"
grep -Eq '^guestITermPiVersion=[0-9]+\.[0-9]+\.[0-9]+' "$D/guest/tmp/ah.out"
echo 'ok: guest UI automation opened an iTerm window and ran pi successfully'
