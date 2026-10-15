#!/usr/bin/env bash
# Exercise real CLI workers and WebUI in-memory runtimes inside a disposable guest.
set -euo pipefail
job=$(mktemp -d)
agents=''
memory=''
cleanup() {
    rc=$?
    trap - EXIT
    [ -z "$memory" ] || kill "$memory" 2>/dev/null || true
    [ -z "$agents" ] || kill "$agents" 2>/dev/null || true
    [ -z "$memory" ] || wait "$memory" 2>/dev/null || true
    [ -z "$agents" ] || wait "$agents" 2>/dev/null || true
    if [ "$rc" != 0 ]; then
        for log in "$job"/*.log; do [ ! -f "$log" ] || tail -c 16000 "$log"; done
    fi
    exit "$rc"
}
trap cleanup EXIT
export PI_CODING_AGENT_DIR="$job/agent" PI_WEB_DATA_DIR="$job/web"
export PI_OBSERVER_DIR="$PI_CODING_AGENT_DIR/observer"
export PI_OFFLINE=1 PI_OBSERVER_TEST_IN_MEMORY=1 PI_WEB_PLUGIN_CATALOG_URL=off PI_WEB_LOCALE=en
bash /tmp/ahsb-push/pi-observer/install-guest.sh
node /tmp/ahsb-push/pi-observer/tests/agents.mjs > "$job/agents.log" 2>&1 &
agents=$!
for _ in $(seq 1 150); do
    [ ! -f "$PI_CODING_AGENT_DIR/agents-ready" ] || break
    kill -0 "$agents"
    sleep 0.1
done
test -f "$PI_CODING_AGENT_DIR/agents-ready"
echo 'observer-autoload-two-agents PASS'
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
mkdir -p /tmp/ah-artifacts
cp "$PI_CODING_AGENT_DIR/memory-ready.json" "$PI_CODING_AGENT_DIR/model-evidence.jsonl" /tmp/ah-artifacts/
kill "$memory"
wait "$memory"
memory=''
node - <<'NODE'
const fs=require('node:fs');const assert=require('node:assert/strict');
const evidence=JSON.parse(fs.readFileSync('/tmp/ah-artifacts/memory-ready.json'));
const names=fs.readdirSync(process.env.PI_OBSERVER_DIR);
for(const id of evidence.snapshotIds)assert.ok(!names.some(name=>name.startsWith(id+'.')), 'disposed WebUI session left a snapshot or summary');
console.log('observer-webui-inmemory-shutdown-cleanup PASS');
NODE
kill "$agents"
wait "$agents"
agents=''
test "$(find "$PI_OBSERVER_DIR" -type f | wc -l | tr -d ' ')" = 0
echo 'observer-shutdown-cleanup PASS'
