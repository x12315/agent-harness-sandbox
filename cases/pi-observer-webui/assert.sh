#!/usr/bin/env bash
set -euo pipefail
D=${1:?usage: assert.sh <run-dir>}

[ "$(cat "$D/guest/tmp/ah.rc")" = 0 ]
rg 'pi-observer' "$D/guest/tmp/ah.out" >/dev/null
rg 'webui-plugin-served' "$D/guest/tmp/ah.out" >/dev/null
echo 'ok: pi-web-ui installed the observer tab and served its client entry inside the disposable guest'

[ ! -e "$D/guest/root/.pi/agent/extensions/pi-observer.ts" ]
echo 'ok: WebUI tab deployment did not persist a Pi extension on the guest image'
