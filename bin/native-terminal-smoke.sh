#!/usr/bin/env bash
# Guest-only smoke: a native X11 xterm window must execute a shell on a PTY.
set -euo pipefail
D=/tmp/ah-artifacts/native-terminal
mkdir -p "$D"
for tool in Xvfb xwininfo xterm; do command -v "$tool"; done
{ xterm -version; node --version; pi --version; } > "$D/versions.txt"
export DISPLAY=:91
Xvfb "$DISPLAY" -screen 0 1024x768x24 -nolisten tcp > "$D/xvfb.log" 2>&1 &
XVFB_PID=$!
XTERM_PID=
cleanup() {
    [ -z "$XTERM_PID" ] || kill "$XTERM_PID" 2>/dev/null || true
    kill "$XVFB_PID" 2>/dev/null || true
}
trap cleanup EXIT
for _ in $(seq 1 50); do
    xwininfo -root > "$D/root.txt" 2>/dev/null && break
    kill -0 "$XVFB_PID"
    sleep 0.1
done
xwininfo -root > "$D/root.txt"
xterm -title ahsb-native-terminal -geometry 80x24 -fa 'DejaVu Sans Mono' -hold -e bash -c 'tty > /tmp/ah-artifacts/native-terminal/tty.txt; stty size > /tmp/ah-artifacts/native-terminal/size.txt; printf "native-shell-ok\n" | tee /tmp/ah-artifacts/native-terminal/shell.txt' > "$D/xterm.log" 2>&1 &
XTERM_PID=$!
for _ in $(seq 1 50); do
    if xwininfo -name ahsb-native-terminal > "$D/window.txt" 2>/dev/null && [ -s "$D/shell.txt" ]; then break; fi
    kill -0 "$XTERM_PID"
    sleep 0.1
done
xwininfo -root -tree > "$D/tree.txt"
xwininfo -name ahsb-native-terminal > "$D/window.txt"
grep -q 'Map State: IsViewable' "$D/window.txt"
grep -q '^/dev/pts/[0-9]' "$D/tty.txt"
grep -qx '24 80' "$D/size.txt"
grep -qx 'native-shell-ok' "$D/shell.txt"
printf 'native-terminal smoke passed\n'
