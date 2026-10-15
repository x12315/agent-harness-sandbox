#!/usr/bin/env bash
# End-to-end check inside a disposable guest; browser commands never run on host.
set -euo pipefail
job=$(mktemp -d)
server=''
agents=''
memory=''
session="observer-e2e-$$"
cleanup() {
    rc=$?
    trap - EXIT
    if [ "$rc" != 0 ]; then
        for log in "$job"/*.log "$job"/last.json; do
            [ ! -f "$log" ] || { echo "== $log =="; tail -c 16000 "$log"; }
        done
    fi
    # Keep live agents and viewer for the runner's screenshot; clone teardown owns successful cleanup.
    [ "$rc" != 0 ] || exit 0
    [ -z "$server" ] || kill "$server" 2>/dev/null || true
    [ -z "$agents" ] || kill "$agents" 2>/dev/null || true
    [ -z "$memory" ] || kill "$memory" 2>/dev/null || true
    [ -z "$memory" ] || wait "$memory" 2>/dev/null || true
    [ -z "$server" ] || wait "$server" 2>/dev/null || true
    [ -z "$agents" ] || wait "$agents" 2>/dev/null || true
    # Leave the browser open for the runner's guest screenshot, then VM deletion.
    exit "$rc"
}
trap cleanup EXIT
export PI_CODING_AGENT_DIR="$job/agent"
export PI_WEB_DATA_DIR="$job/web"
export PI_OBSERVER_DIR="$PI_CODING_AGENT_DIR/observer"
export PI_OBSERVER_TEST_IN_MEMORY=1 PI_OFFLINE=1
mkdir -p "$job/work"
bash /tmp/ahsb-push/pi-observer/install-guest.sh
node /tmp/ahsb-push/pi-observer/tests/agents.mjs > "$job/agents.log" 2>&1 &
agents=$!
for _ in $(seq 1 100); do
    [ ! -f "$PI_CODING_AGENT_DIR/agents-ready" ] || break
    kill -0 "$agents"
    sleep 0.1
done
test -f "$PI_CODING_AGENT_DIR/agents-ready"
echo 'observer-autoload-two-agents PASS'
# Server and CLI use the same pinned Pi runtime; no real model credentials.
export PI_WEB_PLUGIN_CATALOG_URL=off
export PI_WEB_LOCALE=en
PI_OBSERVER_INTERVAL_MINUTES=0.05 node /tmp/ahsb-push/pi-observer/tests/webui-inmemory.mjs > "$job/memory.log" 2>&1 &
memory=$!
for _ in $(seq 1 300); do
    [ ! -f "$PI_CODING_AGENT_DIR/memory-summaries-ready" ] || break
    kill -0 "$memory"
    sleep 0.1
done
test -f "$PI_CODING_AGENT_DIR/memory-summaries-ready"
echo 'observer-webui-inmemory-two-sessions PASS'
echo 'observer-webui-inmemory-summaries PASS'
pi-web-ui \
    --host 127.0.0.1 --port 8799 --cwd "$job/work" --data-dir "$PI_WEB_DATA_DIR" --no-browser \
    > "$job/server.log" 2>&1 &
server=$!
for _ in $(seq 1 100); do
    if curl -fsS --max-time 1 http://127.0.0.1:8799/ >/dev/null 2>&1; then break; fi
    kill -0 "$server"
    sleep 0.1
done
curl -fsS --max-time 2 http://127.0.0.1:8799/ >/dev/null
echo 'observer-webui-ready PASS'

browser() {
    if ! agent-browser --session "$session" --json "$@" > "$job/last.json"; then
        tail -c 16000 "$job/last.json"
        return 1
    fi
    node -e 'const fs=require("node:fs");const r=JSON.parse(fs.readFileSync(process.argv[1]));if(!r.success)throw Error(r.error);' "$job/last.json"
}
ref() {
    node -e 'const fs=require("node:fs");const r=JSON.parse(fs.readFileSync(process.argv[1]));const items=Object.entries(r.data.refs||{}).filter(([,v])=>v.role===process.argv[2]&&v.name===process.argv[3]);if(!items.length)process.exit(1);console.log("@"+items.at(-1)[0]);' "$job/last.json" "$1" "$2"
}
browser --headed open http://127.0.0.1:8799/
browser wait --text 'Pi Observer'
browser snapshot
if grep -q 'pi agent config not detected' "$job/last.json"; then
    browser click "$(ref button Close)"
    browser snapshot
fi
browser click "$(ref tab 'Pi Observer Pi Observer')"
browser wait --text 'Allow read access'
browser get text body
! grep -q 'observer-work-main' "$job/last.json"
! grep -q 'observer-work-child' "$job/last.json"
! grep -q 'observer-memory-parent' "$job/last.json"
! grep -q 'observer-memory-child' "$job/last.json"
echo 'observer-unauthorized-hidden PASS'
browser find role button click --name 'Allow read access'
browser wait --text 'Read Pi Observer snapshots'
browser snapshot
browser click "$(ref button Allow)"
browser wait --text 'observer-work-main'
browser wait --text 'observer-work-child'
browser wait --text 'observer-memory-parent'
browser wait --text 'observer-memory-child'
browser wait --text 'Independent and in-memory Pi sessions are working in the disposable guest.'
browser get text body
node -e 'const fs=require("node:fs");const r=JSON.parse(fs.readFileSync(process.argv[1]));for(const text of ["observer-work-main","observer-work-child","observer-memory-parent","observer-memory-child","thinking","Independent and in-memory Pi sessions are working in the disposable guest.","5 observed sessions · 4 processes · 4 active"])if(!r.data.text.toLowerCase().includes(text.toLowerCase()))throw Error("missing "+text);console.log("observer-multiple-agents-and-summary PASS");' "$job/last.json"
# A new snapshot must appear through scheduled refresh, without a UI click.
node -e 'const fs=require("node:fs");const dir=process.env.PI_OBSERVER_DIR;fs.writeFileSync(dir+"/refresh.snapshot.json",JSON.stringify({id:"refresh",pid:99999,cwd:"scheduled-refresh-proof",active:false,phase:"idle",updatedAt:new Date().toISOString()}));'
browser wait --text 'scheduled-refresh-proof'
echo 'observer-scheduled-refresh PASS'
node -e 'require("node:fs").unlinkSync(process.env.PI_OBSERVER_DIR+"/refresh.snapshot.json");'
browser find role button click --name Refresh
browser wait --text 'observer-work-main'
browser wait --text 'observer-work-child'
browser get text body
! grep -q 'scheduled-refresh-proof' "$job/last.json"
