#!/usr/bin/env bash
set -euo pipefail
D=${1:?usage: assert.sh <run-dir>}
test "$(< "$D/guest/tmp/ah.rc")" = 0
grep -q 'runtime-business-command PASS' "$D/guest/tmp/ah.out"
node - "$D/runtime.json" <<'NODE'
const fs=require('node:fs');const assert=require('node:assert/strict');
const r=JSON.parse(fs.readFileSync(process.argv[2]));
assert.equal(r.ok,true);assert.equal(r.platform,'linux');assert.equal(r.arch,'x64');assert.equal(r.nativePty,true);
assert.deepEqual(r.tools,{pi:'0.87.1','pi-web-ui':'0.96.1','agent-browser':'0.38.2',claude:'2.1.283'});
NODE
echo 'ok: actual Linux tools and native PTY pass before business execution'
