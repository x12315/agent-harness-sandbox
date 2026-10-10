import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFile } from 'node:child_process';
import { mkdtemp, mkdir, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';
import test from 'node:test';

const run = promisify(execFile);
const helper = new URL('../bin/prepare-project-case.mjs', import.meta.url);

async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'ahsb-project-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const project = join(root, 'consumer project');
  const snapshot = join(root, 'snapshot');
  const caseDir = join(project, 'tests/sandbox/smoke');
  await mkdir(caseDir, { recursive: true });
  await mkdir(snapshot);
  await writeFile(join(caseDir, 'cmd'), 'true\n');
  return { project, snapshot, caseDir };
}

const prepare = ({ project, snapshot }) => run(process.execPath, [helper.pathname, project, 'smoke', snapshot]);

test('snapshots only the selected consumer case and declared inputs, with digests', async t => {
  const f = await fixture(t);
  await mkdir(join(f.project, 'src'));
  await writeFile(join(f.project, 'src/input.txt'), 'input\n');
  await writeFile(join(f.project, 'private.txt'), 'not an input');
  await writeFile(join(f.caseDir, 'push'), 'src/input.txt:/tmp/ahsb-push/input.txt\n');
  await prepare(f);
  const manifest = await readFile(join(f.snapshot, 'project-source.sha256'), 'utf8');
  const digest = createHash('sha256').update('input\n').digest('hex');
  assert.ok(manifest.includes(`${digest}  ./src/input.txt\n`));
  await assert.rejects(readFile(join(f.snapshot, 'private.txt')), { code: 'ENOENT' });
  await writeFile(join(f.project, 'src/input.txt'), 'changed after snapshot');
  assert.equal(await readFile(join(f.snapshot, 'src/input.txt'), 'utf8'), 'input\n');
});

for (const entry of ['../secret:/tmp/ahsb-push/input', 'cmd:/etc/passwd', 'cmd:/tmp/ahsb-push/../outside', '/etc/passwd:/tmp/ahsb-push/input']) {
  test(`rejects invalid input declaration: ${entry}`, async t => {
    const f = await fixture(t);
    await writeFile(join(f.caseDir, 'push'), entry + '\n');
    await assert.rejects(prepare(f), /invalid push entry/);
  });
}

test('rejects case symlinks and project-escaping source symlinks', async t => {
  const f = await fixture(t);
  await symlink('/etc/passwd', join(f.caseDir, 'secret'));
  await assert.rejects(prepare(f), /must not be symlinks/);
  await rm(join(f.caseDir, 'secret'));
  await symlink('/etc/passwd', join(f.project, 'input'));
  await writeFile(join(f.caseDir, 'push'), 'input:/tmp/ahsb-push/input\n');
  await assert.rejects(prepare(f), /input escapes project/);
});
