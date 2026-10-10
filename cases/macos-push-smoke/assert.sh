#!/usr/bin/env bash
set -euo pipefail
D=${1:?usage: assert.sh <run-dir>}

[ "$(cat "$D/guest/tmp/ah.rc")" = 0 ]
[ -s "$D/macos-push.sha256" ]
rg 'fixture.txt -> /tmp/ahsb-push/fixture.txt' "$D/macos-push.sha256" >/dev/null
echo 'ok: repository fixture was injected only into the disposable macOS clone'
