#!/usr/bin/env bash
set -euo pipefail
D=${1:?usage: assert.sh <run-dir>}
[ "$(cat "$D/guest/tmp/ah.rc")" = 0 ]
[ ! -s "$D/guest/tmp/ah.err" ]
[ -s "$D/gui.png" ]
grep -Eq '^guestCalculatorWindows=[1-9][0-9]*$' "$D/guest/tmp/ah.out"
echo 'ok: guest Calculator has a window and guest screenshot evidence was collected'
