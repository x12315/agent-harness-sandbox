#!/usr/bin/env bash
set -euo pipefail
D=${1:?usage: assert.sh <run-dir>}
test "$(< "$D/guest/tmp/ah.rc")" = 0
for proof in observer-real-provider-two-agents observer-real-provider-independent-summaries observer-real-provider-shutdown-cleanup; do
    grep -q "$proof PASS" "$D/guest/tmp/ah.out"
done
node --input-type=module - "$D" <<'NODE'
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
const d=process.argv[2], output=fs.readFileSync(path.join(d,'guest/tmp/ah.out'),'utf8');
const data=JSON.parse(Buffer.from(output.match(/^REAL_PROVIDER_EVIDENCE=(.+)$/m)[1],'base64').toString());
fs.writeFileSync(path.join(d,'real-provider.json'),JSON.stringify(data,null,2));
assert.equal(data.provider,'deepseek'); assert.equal(data.model,'deepseek-flash'); assert.equal(data.forwarded,2);
assert.equal(data.reports.length,2); assert.equal(new Set(data.reports.map(report=>report.pid)).size,2);
for(const report of data.reports)assert.ok(data.replies.includes(report.text));
assert.equal(data.snapshots.filter(snapshot=>snapshot.active).length,2);
NODE
echo 'ok: two actual guest Pi observers completed through DeepSeek Flash, without fallback, then cleaned up'
