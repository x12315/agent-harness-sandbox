#!/usr/bin/env bash
set -euo pipefail
D=${1:?usage: assert.sh <run-dir>}
A=$D/guest/tmp/ah-artifacts/native-terminal
test "$(< "$D/guest/tmp/ah.rc")" = 0
grep -q 'Map State: IsViewable' "$A/window.txt"
grep -q '"ahsb-native-terminal"' "$A/tree.txt"
grep -q '^/dev/pts/[0-9]' "$A/tty.txt"
grep -qx '24 80' "$A/size.txt"
grep -qx 'native-shell-ok' "$A/shell.txt"
grep -Fqx 'XTerm(411)' "$A/versions.txt"
printf 'ok: native xterm window, PTY and child shell evidence\n'
