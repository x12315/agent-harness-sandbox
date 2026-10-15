#!/usr/bin/env bash
# Install trusted observer sources in a disposable guest, never on the host.
set -euo pipefail
SOURCE=$(cd "$(dirname "$0")" && pwd -P)
case "$SOURCE" in /tmp/ahsb-push/*|/private/tmp/ahsb-push/*) ;; *) echo 'run only from sources pushed into a disposable guest' >&2; exit 2;; esac
if [ ! -f /etc/ahsb-guest ] && [ -z "${SSH_CONNECTION:-}" ]; then
    echo 'sandbox guest marker or guest SSH session required' >&2
    exit 2
fi
AGENT=${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}
DATA=${PI_WEB_DATA_DIR:-$HOME/.pi-web}
DEST="$DATA/plugins/pi-observer"
SOURCES=(observer.ts webui/manifest.json webui/index.mjs webui/sdk/index.mjs webui/client/entry.mjs)
TARGETS=("$AGENT/extensions/pi-observer.ts" "$DEST/manifest.json" "$DEST/index.mjs" "$DEST/sdk/index.mjs" "$DEST/client/entry.mjs")
# Refuse conflicting files rather than overwrite guest-owned configuration.
for i in "${!SOURCES[@]}"; do
    test -f "$SOURCE/${SOURCES[$i]}"
    target=${TARGETS[$i]}
    if [ -e "$target" ] || [ -L "$target" ]; then
        [ ! -L "$target" ] && cmp -s "$SOURCE/${SOURCES[$i]}" "$target" || {
            echo "observer installation conflicts with existing file: $target" >&2
            exit 2
        }
    fi
done
umask 077
for i in "${!SOURCES[@]}"; do
    target=${TARGETS[$i]}
    mkdir -p "${target%/*}"
    cp "$SOURCE/${SOURCES[$i]}" "$target"
done
mkdir -p "${PI_OBSERVER_DIR:-$AGENT/observer}"
printf 'observer installed: plain pi auto-loads; Pi Observer tab reads all processes\n'
