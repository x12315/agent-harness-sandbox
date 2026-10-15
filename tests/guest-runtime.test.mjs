import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { checkRuntime, parseRequirements } from '../bin/guest-runtime.mjs';

test('requirements permit only supported tools at exact versions', () => {
  assert.deepEqual(parseRequirements('{"pi":"0.87.1","pi-web-ui":"0.96.1"}'), { pi: '0.87.1', 'pi-web-ui': '0.96.1' });
  for (const text of ['{}', '[]', 'null', '{"pi":"latest"}', '{"pi":"^0.87.1"}', '{"shell":"1.0.0"}', '{"pi":87}']) {
    assert.throws(() => parseRequirements(text));
  }
});

test('checks the declared runtime entry, not an unrelated PATH shim, and never installs missing tools', async t => {
  const root = await mkdtemp(join(tmpdir(), 'ahsb-runtime-check-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  await assert.rejects(checkRuntime({ pi: '0.87.1' }, root), /missing pi@0.87.1/);
  const pkg = join(root, 'node_modules/@earendil-works/pi-coding-agent');
  await mkdir(pkg, { recursive: true });
  const metadata = { version: '0.87.1', bin: { pi: 'cli.cjs' } };
  await writeFile(join(pkg, 'package.json'), JSON.stringify(metadata));
  await writeFile(join(pkg, 'cli.cjs'), '#!/usr/bin/env node\nif(process.env.PI_OFFLINE!=="1")throw Error("version probe must stay offline");console.log("0.87.1")\n');
  const evidence = await checkRuntime({ pi: '0.87.1' }, root);
  assert.equal(evidence.ok, true);
  assert.equal(evidence.nodeAbi, process.versions.modules);
  assert.deepEqual(evidence.tools, { pi: '0.87.1' });
  await assert.rejects(checkRuntime({ pi: '0.88.0' }, root), /expected 0.88.0, installed 0.87.1/);
  await writeFile(join(pkg, 'cli.cjs'), '#!/usr/bin/env node\nconsole.log("0.88.0")\n');
  await assert.rejects(checkRuntime({ pi: '0.87.1' }, root), /real CLI version does not match/);
  await writeFile(join(pkg, 'cli.cjs'), '#!/usr/bin/env node\nconsole.log("0.87.10")\n');
  await assert.rejects(checkRuntime({ pi: '0.87.1' }, root), /real CLI version does not match/);
  assert.equal(await readFile(join(pkg, 'package.json'), 'utf8'), JSON.stringify(metadata));
});

test('CLI validation executes through symlinked paths, including macOS /tmp aliases', async t => {
  const root = await mkdtemp(join(tmpdir(), 'ahsb-runtime-cli-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const alias = join(root, 'check.mjs');
  await symlink(new URL('../bin/guest-runtime.mjs', import.meta.url).pathname, alias);
  const file = join(root, 'requires.json');
  await writeFile(file, '{"pi":"latest"}');
  await assert.rejects(promisify(execFile)(process.execPath, [alias, '--validate', file]), error => error.code === 78);
  await writeFile(file, '{"pi":"0.87.1"}');
  await promisify(execFile)(process.execPath, [alias, '--validate', file]);
});

test('WebUI requires a native PTY, not just a matching package label', async t => {
  const root = await mkdtemp(join(tmpdir(), 'ahsb-pty-check-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const pkg = join(root, 'node_modules/pi-web-ui');
  await mkdir(pkg, { recursive: true });
  await writeFile(join(pkg, 'package.json'), JSON.stringify({ version: '0.96.1', bin: { 'pi-web-ui': 'cli.cjs' } }));
  await writeFile(join(pkg, 'cli.cjs'), '#!/usr/bin/env node\nconsole.log("0.96.1")\n');
  await assert.rejects(checkRuntime({ 'pi-web-ui': '0.96.1' }, root), /Cannot find module 'node-pty'/);
});
