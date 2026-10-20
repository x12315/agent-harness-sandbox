import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

test('coordination runtime pins one compatible Pi package cohort', async () => {
 const recipe=JSON.parse(await readFile(new URL('../image-deps/package.json',import.meta.url),'utf8'));
 const lock=JSON.parse(await readFile(new URL('../image-deps/package-lock.json',import.meta.url),'utf8'));
 assert.equal(recipe.dependencies['@earendil-works/pi-coding-agent'],'1.1.0');
 assert.equal(recipe.dependencies['pi-web-ui'],'0.100.0');
 for(const name of ['chord','pi-agent-core','pi-ai','pi-codemode','pi-mcp','pi-tui']) {
  const packageName=`@earendil-works/${name}`;
  assert.equal(recipe.overrides[packageName],'1.1.0');
  const packages=Object.entries(lock.packages).filter(([path])=>path.endsWith(`node_modules/${packageName}`));
  assert.ok(packages.length>0,packageName);
  for(const [path,value] of packages) assert.equal(value.version,'1.1.0',path);
 }
});

test('guest preparation persists executable metadata before immediate VM stop and save', async () => {
 const source=await readFile(new URL('../bin/prepare-runtime-guest.sh',import.meta.url),'utf8');
 assert.ok(source.indexOf('chmod u+x')<source.lastIndexOf('\nsync\n'));
 assert.ok(source.indexOf('runtime.json')<source.lastIndexOf('\nsync\n'));
 assert.ok(source.lastIndexOf('\nsync\n')<source.indexOf("echo 'runtime-prepare PASS'"));
});
