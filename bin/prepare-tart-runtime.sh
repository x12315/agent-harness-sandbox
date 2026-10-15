#!/usr/bin/env bash
# Prepare the pinned common runtime in a private macOS clone and save a new stopped base.
# Usage: load the private Tart profile, then bash bin/prepare-tart-runtime.sh <new-base-name>.
set -euo pipefail
umask 077
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NAME=${1:?usage: prepare-tart-runtime.sh <new-base-name>}
[[ $NAME =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || { echo 'invalid new base name' >&2; exit 2; }
: "${TART_BASE_VM:?select an existing stopped macOS base first}"
: "${TART_SSH_KEY:?select the guest key}"
: "${TART_KNOWN_HOSTS:?select the pinned guest host key}"
for tool in tart node npm tar shasum; do command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 2; }; done
! tart get "$NAME" >/dev/null 2>&1 || { echo 'new base name already exists; refusing overwrite' >&2; exit 2; }
LOCK=$(shasum -a 256 "$ROOT/image-deps/package-lock.json" | awk '{print $1}')
CACHE=${AHSB_CACHE_DIR:-$HOME/.cache/agent-harness-sandbox}/runtime-tarballs/darwin-arm64-$LOCK
node "$ROOT/bin/cache-runtime-packages.mjs" darwin arm64 "$CACHE"
INPUT=$(mktemp -d)
INPUT=$(cd "$INPUT" && pwd -P)
trap 'rm -rf "$INPUT"' EXIT
cp "$ROOT/image-deps/package.json" "$ROOT/image-deps/package-lock.json" "$INPUT/"
cp "$ROOT/bin/prepare-runtime-guest.sh" "$ROOT/bin/guest-runtime.mjs" "$INPUT/"
tar -czf "$INPUT/npm-cache.tar.gz" -C "$CACHE" .
node - "$INPUT" <<'NODE'
const fs=require('node:fs');const root=process.argv[2];
const packages=JSON.parse(fs.readFileSync(root+'/package.json')).dependencies;
const tools={pi:packages['@earendil-works/pi-coding-agent'],'pi-web-ui':packages['pi-web-ui'],'agent-browser':packages['agent-browser'],claude:packages['@anthropic-ai/claude-code']};
fs.writeFileSync(root+'/requires.json',JSON.stringify(tools)+'\n');
NODE
mkdir "$INPUT/case"
printf 'macos-tart\n' > "$INPUT/case/target"
printf 'bash /tmp/ahsb-push/runtime-prepare/prepare-runtime-guest.sh\n' > "$INPUT/case/cmd"
for file in package.json package-lock.json prepare-runtime-guest.sh guest-runtime.mjs npm-cache.tar.gz requires.json; do
    printf '%s:/tmp/ahsb-push/runtime-prepare/%s\n' "$file" "$file"
done > "$INPUT/case/push"
(cd "$INPUT" && find . -type f ! -name project-source.sha256 -exec shasum -a 256 {} + | LC_ALL=C sort) > "$INPUT/project-source.sha256"
AHSB_CASE_DIR="$INPUT/case" AHSB_INPUT_ROOT="$INPUT" TART_SAVE_BASE="$NAME" CASE_TIMEOUT=${PREPARE_TIMEOUT:-180} \
    bash "$ROOT/bin/run-tart-case.sh" tart-runtime-prepare
printf 'prepared base: %s; select with TART_BASE_VM=%s (private profile unchanged)\n' "$NAME" "$NAME"
