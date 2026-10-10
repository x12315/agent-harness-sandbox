#!/usr/bin/env bash
set -euo pipefail

node --test /work/webui/index.test.mjs
pi-web-ui install /work/webui --name pi-observer --data-dir /root/.pi-web-observer-test --no-build
pi-web-ui plugins --data-dir /root/.pi-web-observer-test

PI_WEB_DATA_DIR=/root/.pi-web-observer-test PI_WEB_PORT=8799 PI_WEB_HOST=127.0.0.1 \
	pi-web-ui --no-browser --cwd /work >/tmp/pi-web-ui.out 2>/tmp/pi-web-ui.err &
server=$!
ready=0
for _ in $(seq 1 20); do
	if node -e 'fetch("http://127.0.0.1:8799/plugins/pi-observer/client/entry.mjs").then((response) => process.exit(response.ok ? 0 : 1)).catch(() => process.exit(1))'; then
		ready=1
		break
	fi
	sleep 1
done

kill "$server" 2>/dev/null || true
sleep 1
kill -9 "$server" 2>/dev/null || true
wait "$server" 2>/dev/null || true
[ "$ready" = 1 ] || {
	cat /tmp/pi-web-ui.out
	cat /tmp/pi-web-ui.err >&2
	exit 1
}
printf '%s\n' 'webui-plugin-served'
