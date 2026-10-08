#!/usr/bin/env bash
# Run deterministic browser/CDP debug checks only inside the sandbox Linux image.
set -euo pipefail
[ -f /etc/ahsb-guest ] && [ "$(uname -s)" = Linux ] && systemd-detect-virt --vm --quiet || { echo 'browser checks require the sandbox Linux VM; refusing host execution' >&2; exit 2; }
for tool in agent-browser chromium node jq timeout; do command -v "$tool" >/dev/null || { echo "missing guest tool: $tool" >&2; exit 2; }; done
MODE=${1:?usage: exercise.sh <headless|headed>}
case "$MODE" in headless|headed) ;; *) exit 2 ;; esac
ROOT=$(cd "$(dirname "$0")" && pwd)
RUN=/tmp/ah-artifacts/browser-debug
mkdir -p "$RUN"
SESSION=ahsb-browser-$$
CDP_PORT=
CHROME_PID=
SERVER_PID=
XVFB_PID=
cleanup() {
    [ -z "$CDP_PORT" ] || agent-browser --session "$SESSION" --cdp "$CDP_PORT" close >/dev/null 2>&1 || true
    for pid in "$CHROME_PID" "$SERVER_PID" "$XVFB_PID"; do
        [ -z "$pid" ] || { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }
    done
    rm -rf "$RUN/first-profile" "$RUN/second-profile"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
agent-browser --version > "$RUN/agent-browser-version.txt"
chromium --version > "$RUN/chromium-version.txt"
printf '%s\n' "$MODE" > "$RUN/mode.txt"
if [ "$MODE" = headed ]; then
    command -v Xvfb >/dev/null || { echo 'missing guest Xvfb' >&2; exit 2; }
    Xvfb -displayfd 3 -screen 0 1280x800x24 -nolisten tcp -ac 3> "$RUN/display-number" > "$RUN/xvfb.log" 2>&1 &
    XVFB_PID=$!
    for _ in $(seq 1 50); do [ ! -s "$RUN/display-number" ] || break; kill -0 "$XVFB_PID"; sleep 0.1; done
    [ -s "$RUN/display-number" ] || { echo 'guest Xvfb not ready' >&2; exit 1; }
    export DISPLAY=:$(head -1 "$RUN/display-number")
fi
node "$ROOT/server.mjs" "$RUN/site.json" "$RUN/site-requests.jsonl" > "$RUN/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do [ ! -s "$RUN/site.json" ] || break; kill -0 "$SERVER_PID"; sleep 0.1; done
[ -s "$RUN/site.json" ] || { echo 'fixture site not ready' >&2; exit 1; }
URL=$(jq -r .url "$RUN/site.json")
start_chrome() {
    local profile=$1
    mkdir -p "$profile"
    local flags=(--no-sandbox --disable-dev-shm-usage --no-first-run --disable-background-networking --disable-sync --remote-debugging-address=127.0.0.1 --remote-debugging-port=0 "--user-data-dir=$profile")
    [ "$MODE" != headless ] || flags+=(--headless=new)
    printf '%s\n' "${flags[@]}" > "$RUN/chrome-flags.txt"
    chromium "${flags[@]}" about:blank > "$RUN/chrome.log" 2>&1 &
    CHROME_PID=$!
    for _ in $(seq 1 100); do [ ! -s "$profile/DevToolsActivePort" ] || break; kill -0 "$CHROME_PID"; sleep 0.1; done
    [ -s "$profile/DevToolsActivePort" ] || { echo 'guest Chrome CDP endpoint not ready' >&2; exit 1; }
    CDP_PORT=$(head -1 "$profile/DevToolsActivePort")
    printf '%s\n' "$CDP_PORT" > "$RUN/cdp-port.txt"
}
ab() {
    printf '%q ' "$@" >> "$RUN/commands.log"; printf '\n' >> "$RUN/commands.log"
    agent-browser --session "$SESSION" --cdp "$CDP_PORT" --json "$@"
}
start_chrome "$RUN/first-profile"
ab open "$URL" > "$RUN/navigation.json"
ab wait --fn 'document.getElementById("session").textContent === "Signed out"' > "$RUN/ready.json"
ab trace start > "$RUN/trace-start.json"
ab network har start > "$RUN/har-start.json"
ab snapshot -i > "$RUN/snapshot.json"
ab find label Message fill 'VM-only browser input' > "$RUN/fill.json"
ab find role button click --name 'Echo message' > "$RUN/click.json"
ab wait --text 'VM-only browser input' > "$RUN/echo-wait.json"
ab find label Username fill sandbox > "$RUN/username.json"
ab find role button click --name 'Sign in' > "$RUN/login.json"
ab wait --fn 'document.getElementById("session").textContent === "Signed in"' > "$RUN/login-wait.json"
ab state save "$RUN/state.json" > "$RUN/state-save.json"
ab tab new --label second "$URL/second" > "$RUN/tab-new.json"
ab wait --text 'Second page' > "$RUN/tab-wait.json"
ab tab > "$RUN/tabs.json"
ab tab t1 > "$RUN/tab-return.json"
ab wait --fn 'document.getElementById("session").textContent === "Signed in"' > "$RUN/tab-return-wait.json"
ab find role button click --name 'Trigger diagnostics' > "$RUN/debug-click.json"
ab wait --fn 'document.getElementById("diagnostics").textContent.includes("dropped")' > "$RUN/debug-wait.json"
ab console > "$RUN/console.json"
ab errors > "$RUN/errors.json"
ab network requests > "$RUN/network.json"
if ab wait '#missing-debug-target' --timeout 1000 > "$RUN/expected-timeout.json" 2> "$RUN/expected-timeout.err"; then
    echo 'missing selector unexpectedly succeeded' >&2; exit 1
fi
printf '%s\n' '({message:document.getElementById("result").textContent,session:document.getElementById("session").textContent,diagnostics:JSON.parse(document.getElementById("diagnostics").textContent)})' \
    | ab eval --stdin > "$RUN/dom.json"
ab screenshot "$RUN/browser.png" > "$RUN/screenshot.json"
if [ "$MODE" = headed ]; then xwininfo -root -tree > "$RUN/headed-windows.txt"; fi
ab network har stop "$RUN/network.har" > "$RUN/har-stop.json"
ab trace stop "$RUN/trace.json" > "$RUN/trace-stop.json"
ab close > "$RUN/first-close.json"
kill "$CHROME_PID"; wait "$CHROME_PID" 2>/dev/null || true
CHROME_PID=
CDP_PORT=
SESSION=ahsb-restored-$$
start_chrome "$RUN/second-profile"
ab open "$URL" > "$RUN/fresh-navigation.json"
ab wait --fn 'document.getElementById("session").textContent === "Signed out"' > "$RUN/fresh-session.json"
ab state load "$RUN/state.json" > "$RUN/state-load.json"
ab reload > "$RUN/reload.json"
ab wait --fn 'document.getElementById("session").textContent === "Signed in"' > "$RUN/restored-wait.json"
printf '%s\n' '({restored:document.getElementById("session").textContent==="Signed in"})' | ab eval --stdin > "$RUN/restored.json"
node "$ROOT/assert-evidence.mjs" "$RUN"
# Keep only diagnostic evidence, not browser caches or profiles, in the serial archive.
rm -rf "$RUN/first-profile" "$RUN/second-profile"
echo 'BROWSER_DEBUG_PASS'
