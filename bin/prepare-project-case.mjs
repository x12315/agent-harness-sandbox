#!/usr/bin/env node
/** Snapshot one trusted consumer case and its declared inputs outside both repositories. */
import { createHash } from 'node:crypto';
import { cp, lstat, mkdir, readFile, readdir, realpath, writeFile } from 'node:fs/promises';
import { isAbsolute, join, relative, resolve, sep } from 'node:path';

const [projectPath, caseId, destination] = process.argv.slice(2);
if (!projectPath || !destination || !/^[a-z0-9][a-z0-9-]*$/.test(caseId ?? '')) {
  throw new Error('usage: prepare-project-case.mjs <project> <case-id> <empty-directory>');
}
const project = await realpath(projectPath);
const caseRelative = `tests/sandbox/${caseId}`;
const files = new Set();

function confined(root, path) {
  const rel = relative(root, path);
  return rel !== '..' && !rel.startsWith(`..${sep}`) && !isAbsolute(rel);
}

async function collect(path) {
  const rel = relative(project, path).split(sep).join('/');
  if (!confined(project, path) || !/^[a-zA-Z0-9_./-]+$/.test(rel)) {
    throw new Error(`unsupported or escaping project path: ${rel}`);
  }
  const stat = await lstat(path);
  if (stat.isSymbolicLink()) throw new Error(`project case inputs must not be symlinks: ${rel}`);
  if (stat.isDirectory()) {
    for (const entry of await readdir(path)) await collect(join(path, entry));
  } else if (stat.isFile()) {
    files.add(rel);
  } else {
    throw new Error(`project case input must be a regular file: ${rel}`);
  }
}

// Check parents too: a symlinked tests directory must not redirect outside the project.
const caseDirectory = resolve(project, caseRelative);
if (!confined(project, await realpath(caseDirectory))) throw new Error('case directory escapes project');
await collect(caseDirectory);
if (!files.has(`${caseRelative}/cmd`)) throw new Error(`missing case cmd: ${caseRelative}`);

for (const manifest of ['push', 'macos-push']) {
  const path = `${caseRelative}/${manifest}`;
  if (!files.has(path)) continue;
  for (const line of (await readFile(join(project, path), 'utf8')).split('\n')) {
    if (!line || line.startsWith('#')) continue;
    const match = /^([a-zA-Z0-9_./-]+):(\/tmp\/ahsb-push\/[a-zA-Z0-9_./-]+)$/.exec(line);
    if (!match || isAbsolute(match[1]) || match.slice(1).some(value => value.split('/').some(part => part === '.' || part === '..'))) {
      throw new Error(`invalid ${manifest} entry: ${line}`);
    }
    if (['project-source.sha256', 'sandbox-source.sha256'].includes(match[1])) {
      throw new Error(`reserved snapshot filename: ${match[1]}`);
    }
    const source = resolve(project, match[1]);
    if (!confined(project, await realpath(source))) throw new Error(`input escapes project: ${match[1]}`);
    if (!(await lstat(source)).isFile()) throw new Error(`push source must be a regular file: ${match[1]}`);
    await collect(source);
  }
}

if ((await readdir(destination)).length) throw new Error('snapshot destination must be empty');
const records = [];
for (const rel of [...files].sort()) {
  const target = join(destination, rel);
  await mkdir(resolve(target, '..'), { recursive: true });
  await cp(join(project, rel), target);
  const digest = createHash('sha256').update(await readFile(target)).digest('hex');
  records.push(`${digest}  ./${rel}`);
}
await writeFile(join(destination, 'project-source.sha256'), records.sort().join('\n') + '\n');
