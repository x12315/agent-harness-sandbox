#!/usr/bin/env bash
# Locate reusable assets and private profiles without reading credentials, launching VMs or downloading.
# Always exits zero after discovery; presence is not readiness. Restore instructions: docs/assets.md.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
printf 'mirror catalog: %s/assets/catalog.json\nrestore guide: %s/docs/assets.md\n' "$ROOT" "$ROOT"
for directory in "$HOME/Library/Application Support/agent-harness-sandbox" "$HOME/.config/agent-harness-sandbox"; do
    for name in macos-ready.env download.curl; do
        path="$directory/$name"
        if [ -f "$path" ]; then printf 'private profile found: %s (contents not read)\n' "$path"; fi
    done
done
for path in "$HOME/Library/Application Support/agent-harness-sandbox/images/macos-ready.tvm" \
            "$HOME/.local/share/agent-harness-sandbox/images/macos-ready.tvm"; do
    if [ -f "$path" ]; then printf 'macOS archive found: %s (verify catalog SHA256 before import)\n' "$path"; fi
done
OUT=${OUT:-$HOME/ahsb-build}
for name in ahsb.raw ahsb.vmlinuz ahsb.initrd; do
    if [ -f "$OUT/$name" ]; then printf 'Linux boot file found: %s/%s\n' "$OUT" "$name"; fi
done
if [ -n "${TART_BASE_VM:-}" ]; then printf 'configured TART_BASE_VM: %s\n' "$TART_BASE_VM"; fi
if command -v tart >/dev/null; then
    printf '\nTart inventory (candidates, not proof of GUI readiness; do not move ~/.tart/vms manually):\n'
    tart list || printf 'Tart inventory unavailable; inspect local configuration.\n'
else
    printf 'Tart not installed; macOS cases require an Apple Silicon Mac and Tart.\n'
fi
printf '\nReuse a verified stopped base first; missing assets follow docs/assets.md, not a fresh OS installation.\n'
