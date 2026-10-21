#!/usr/bin/env bash
# Trusted producer recipe: offline package installation and native validation in a preparation clone.
set -euo pipefail
umask 077
SOURCE=/tmp/ahsb-push/runtime-prepare
RUNTIME="$HOME/.local/share/ahsb-runtime"
[ ! -e "$RUNTIME" ] || { echo 'runtime destination already exists; select an unmodified preparation base' >&2; exit 2; }
mkdir -p "$RUNTIME"
CACHE=$(mktemp -d)
trap 'rm -rf "$CACHE"' EXIT
tar -xzf "$SOURCE/npm-cache.tar.gz" -C "$CACHE"
cp "$SOURCE/package.json" "$SOURCE/package-lock.json" "$RUNTIME/"
export NPM_CONFIG_CACHE="$CACHE" NPM_CONFIG_OFFLINE=true
cd "$RUNTIME"
echo 'runtime-prepare stage=offline-install'
npm ci --offline --ignore-scripts --no-audit --no-fund
node node_modules/@anthropic-ai/claude-code/install.cjs
(cd node_modules/node-pty && node scripts/prebuild.js && node scripts/post-install.js)
# node-pty 1.1.0 publishes the macOS spawn helper as 0644; a load check alone misses this.
chmod u+x "node_modules/node-pty/prebuilds/$(node -p 'process.platform + "-" + process.arch')/spawn-helper"
echo 'runtime-prepare stage=actual-cli-and-native-pty'
node "$SOURCE/guest-runtime.mjs" --check "$SOURCE/requires.json" "$RUNTIME" > "$RUNTIME/runtime.json"
echo '==AH_RUNTIME_BEGIN=='
node - "$RUNTIME" <<'NODE'
const fs=require('node:fs');const crypto=require('node:crypto');const path=require('node:path');
const root=process.argv[2];const evidence=JSON.parse(fs.readFileSync(path.join(root,'runtime.json')));
evidence.lockSha256=crypto.createHash('sha256').update(fs.readFileSync(path.join(root,'package-lock.json'))).digest('hex');
evidence.preparedAt=new Date().toISOString();
fs.writeFileSync(path.join(root,'runtime.json'),JSON.stringify(evidence,null,2)+'\n');
console.log(JSON.stringify(evidence));
NODE
echo '==AH_RUNTIME_END=='
rm -rf "$SOURCE"
# Tart stops the preparation VM immediately; persist installed files and executable modes first.
sync
echo 'runtime-prepare PASS'
