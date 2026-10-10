#!/usr/bin/env bash
set -euo pipefail
D=${1:?usage: assert.sh <run-dir>}

[ "$(cat "$D/guest/tmp/ah.rc")" = 0 ]
rg '^\{' "$D/guest/tmp/ah.out" | jq -es 'any(.[]; .command == "get_commands" and .success == true and any(.data.commands[]; .name == "observer"))' \
    >/dev/null
echo 'ok: observer command is discoverable through Pi RPC'

[ -s "$D/guest/root/.pi/agent/extensions/pi-observer.ts" ]
echo 'ok: observer source was deployed only inside the disposable guest'

# At least two original runs plus one independent summary completion must reach the mock.
jq -es 'length >= 3' "$D/mock-requests.jsonl" >/dev/null
echo 'ok: inline and child Pi runs plus a summary completion were observed'

# The original agent keeps Pi's normal tool set; observer adds no model-facing tool.
jq -es '
    any(.[]; (.last_user_text == "say hi" or .last_user_text == "child task")
      and ((.tool_names | sort) == ["bash", "edit", "read", "write"]))
' "$D/mock-requests.jsonl" >/dev/null
echo 'ok: observer did not add a model tool or alter the original tool loadout'

# Every one-shot Pi process keeps its diagnostic snapshot only because this case sets PI_OBSERVER_KEEP_SNAPSHOTS.
[ "$(find "$D/guest/root/.pi/observer-test-snapshots" -name '*.json' -type f | wc -l | tr -d ' ')" -ge 2 ]
echo 'ok: observer collected independent inline and child Pi snapshots'

# The summary request contains only observed snapshots and is separate from the original task request.
jq -es '
    any(.[]; (.last_user_text | contains("<observed-data>")))
' "$D/mock-requests.jsonl" >/dev/null
echo 'ok: summary uses an independent completion with observed snapshots'
