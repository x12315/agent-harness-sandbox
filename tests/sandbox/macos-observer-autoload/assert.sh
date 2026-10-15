#!/usr/bin/env bash
set -euo pipefail
D=${1:?usage: assert.sh <run-dir>}
test "$(< "$D/guest/tmp/ah.rc")" = 0
for proof in observer-autoload-two-agents observer-automatic-summary observer-shutdown-cleanup; do
    grep -q "$proof PASS" "$D/guest/tmp/ah.out"
done
echo 'ok: plain Pi auto-loads two observers, generates an independent automatic summary and cleans up on shutdown'
