#!/usr/bin/env bash
# Read-only discovery finds private locations without exposing their contents or starting a VM.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home/Library/Application Support/agent-harness-sandbox/images" "$TMP/out"
cat > "$TMP/bin/tart" <<'FAKE'
#!/usr/bin/env bash
[ "$*" = list ] || { echo 'unexpected VM mutation' >&2; exit 2; }
printf 'OS State\ndarwin stopped\n'
printf '%s\n' "$*" > "$DISCOVERY_TART_CALL"
FAKE
chmod +x "$TMP/bin/tart"
printf '%s\n' 'PRIVATE_SENTINEL_DO_NOT_PRINT' > "$TMP/home/Library/Application Support/agent-harness-sandbox/macos-ready.env"
printf '%s\n' 'DOWNLOAD_SECRET_DO_NOT_PRINT' > "$TMP/home/Library/Application Support/agent-harness-sandbox/download.curl"
touch "$TMP/home/Library/Application Support/agent-harness-sandbox/images/macos-ready.tvm"
touch "$TMP/out/ahsb.raw" "$TMP/out/ahsb.vmlinuz" "$TMP/out/ahsb.initrd"
HOME="$TMP/home" OUT="$TMP/out" PATH="$TMP/bin:$PATH" TART_BASE_VM=owned-base DISCOVERY_TART_CALL="$TMP/tart-call" \
    bash "$ROOT/bin/locate-assets.sh" > "$TMP/discovery.txt"
grep -q 'private profile found:' "$TMP/discovery.txt"
grep -q 'macOS archive found:' "$TMP/discovery.txt"
grep -q 'Linux boot file found:' "$TMP/discovery.txt"
grep -q 'configured TART_BASE_VM: owned-base' "$TMP/discovery.txt"
grep -q 'assets/catalog.json' "$TMP/discovery.txt"
test "$(cat "$TMP/tart-call")" = list
if grep -Eq 'PRIVATE_SENTINEL|DOWNLOAD_SECRET' "$TMP/discovery.txt"; then echo 'private profile contents leaked' >&2; exit 1; fi
mkdir "$TMP/empty-home"
HOME="$TMP/empty-home" OUT="$TMP/missing-out" PATH="$TMP/bin:$PATH" DISCOVERY_TART_CALL="$TMP/empty-call" \
    bash "$ROOT/bin/locate-assets.sh" > "$TMP/empty.txt"
grep -q 'missing assets follow docs/assets.md' "$TMP/empty.txt"
echo 'PASS: local assets/profiles found, missing assets routed, no credentials read or VM launched'
