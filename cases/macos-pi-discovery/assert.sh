#!/usr/bin/env bash
set -euo pipefail
D=${1:?usage: assert.sh <run-dir>}
[ "$(cat "$D/guest/tmp/ah.rc")" = 0 ]
[ ! -s "$D/guest/tmp/ah.err" ]
command -v jq >/dev/null
jq -es 'any(.[]; .command == "get_commands" and .success == true and (.data.commands | type == "array"))' \
    "$D/guest/tmp/ah.out" >/dev/null
echo 'ok: pi RPC discovery succeeds without stderr in a fresh macOS clone'
