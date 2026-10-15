#!/usr/bin/env bash
set -euo pipefail
D=${1:?usage: assert.sh <run-dir>}
test "$(< "$D/guest/tmp/ah.rc")" = 0
for proof in observer-autoload-two-agents observer-unauthorized-hidden observer-multiple-agents-and-summary observer-scheduled-refresh; do
    grep -q "$proof PASS" "$D/guest/tmp/ah.out"
done
test -s "$D/gui.png"
test -s "$D/project-source.sha256"
echo 'ok: plain Pi auto-loads; headed Observer tab grants read access and displays two live agents, summary and scheduled refresh'
