#!/usr/bin/env bash
set -euo pipefail
D=${1:?}
test "$(< "$D/guest/tmp/ah.rc")" = 0
for marker in observer-autoload-two-agents observer-webui-inmemory-two-sessions observer-webui-inmemory-summaries observer-webui-inmemory-shutdown-cleanup observer-shutdown-cleanup; do
    grep -q "$marker PASS" "$D/guest/tmp/ah.out"
done
echo 'ok: real CLI workers and same-process WebUI runtimes summarize independently and clean up'
