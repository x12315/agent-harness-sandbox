import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readdirSync, renameSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { SessionManager } from '/usr/lib/node_modules/@earendil-works/pi-coding-agent/dist/core/session-manager.js';

const usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
let runNumber = 0;
function fixture() {
  const cwd = mkdtempSync(join(tmpdir(), 'pi-clone-cwd-'));
  const home = mkdtempSync(join(tmpdir(), 'pi-clone-home-'));
  const agentDir = join(home, '.pi', 'agent');
  process.env.PI_CODING_AGENT_DIR = agentDir;
  const session = SessionManager.create(cwd);
  for (let i = 0; i < 3; i++) {
    session.appendMessage({ role: 'user', content: `Question ${i}`, timestamp: Date.now() });
    session.appendMessage({ role: 'assistant', content: [{ type: 'text', text: 'OK' }], api: 'openai-completions', provider: 'openai', model: 'mock', usage, stopReason: 'stop', timestamp: Date.now() });
  }
  session.appendSessionInfo('Original');
  const source = session.getSessionFile();
  const dir = dirname(source);
  return { home, agentDir, source, dir, files: () => readdirSync(dir).filter((name) => name.endsWith('.jsonl')).map((name) => join(dir, name)),
    recycled: () => { const trash = join(dir, '.recycled-session-window'); return existsSync(trash) ? readdirSync(trash).filter((name) => name.endsWith('.jsonl')) : []; } };
}
function tmux(socket, ...args) {
  const result = spawnSync('tmux', ['-L', socket, ...args], { encoding: 'utf8' });
  assert.equal(result.status, 0, `tmux ${args.join(' ')}: ${result.stderr}`);
  return result.stdout;
}
async function waitFor(check, failure) {
  for (let i = 0; i < 30; i++) {
    if (check()) return;
    await delay(160);
  }
  assert.fail(failure);
}
async function launch(socket, data, file, mode) {
  const runtimeDir = mode === 'profile' ? mkdtempSync(join(tmpdir(), 'pi-isolated-profile-')) : data.agentDir;
  const cmd = `HOME=${data.home} PI_CODING_AGENT_DIR=${runtimeDir} pi --offline --session '${file}' -e /work/session-window.ts`;
  tmux(socket, 'new-session', '-d', '-s', socket, '-x', '80', '-y', '24', cmd);
  await waitFor(() => tmux(socket, 'capture-pane', '-p', '-t', socket).includes('claude-'), 'Pi did not display its footer');
  await delay(1800);
}
async function quit(socket) {
  tmux(socket, 'send-keys', '-t', socket, 'C-d');
  await waitFor(() => spawnSync('tmux', ['-L', socket, 'has-session', '-t', socket]).status !== 0, 'Pi did not quit');
}
async function check(kind, mode) {
  const data = fixture();
  const socket = `pi-clone-${process.pid}-${runNumber++}`;
  try {
    await launch(socket, data, data.source, mode);
    tmux(socket, 'send-keys', '-t', socket, `/${kind}`, 'Enter');
    if (kind.startsWith('fork')) {
      await delay(350);
      tmux(socket, 'send-keys', '-t', socket, 'Enter');
    }
    await waitFor(() => data.files().length === 2, `${kind} did not create a branch: ${tmux(socket, 'capture-pane', '-p', '-t', socket)}`);
    const branch = data.files().find((file) => file !== data.source);
    const manager = SessionManager.open(branch, data.dir);
    assert.equal(manager.getHeader().parentSession, data.source);
    assert.ok(manager.getEntries().every((entry) => entry.type !== 'custom' || entry.customType !== 'pi-session-window.branch-created'));
    if (kind.endsWith('-window')) {
      await quit(socket);
      await launch(socket, data, branch, mode);
    }
    if (mode === 'named') {
      tmux(socket, 'send-keys', '-t', socket, '/name kept', 'Enter');
      await waitFor(() => SessionManager.open(branch, data.dir).getSessionName() === 'kept', 'name did not persist');
    }
    let childPath;
    if (mode === 'child' || mode === 'archived-child') {
      const otherCwd = mkdtempSync(join(tmpdir(), 'pi-clone-child-'));
      const child = SessionManager.forkFrom(branch, otherCwd);
      childPath = child.getSessionFile();
      assert.equal(child.getHeader().parentSession, branch);
      if (mode === 'archived-child') {
        const archive = join(dirname(childPath), '.recycled-session-window');
        mkdirSync(archive);
        const archivedPath = join(archive, basename(childPath));
        renameSync(childPath, archivedPath);
        childPath = archivedPath;
      }
    }
    if (kind === 'fork') tmux(socket, 'send-keys', '-t', socket, 'C-c');
    await quit(socket);
    assert.ok(existsSync(data.source), 'source must remain');
    if (mode === 'empty' || mode === 'profile') {
      assert.equal(data.files().length, 1, `unused ${kind} must leave /resume`);
      assert.equal(data.recycled().length, 1, 'recycled clone must remain recoverable');
    } else {
      assert.ok(existsSync(branch), `${kind} must keep the branch (${mode})`);
      assert.equal(data.recycled().length, 0);
      if (childPath) assert.equal(SessionManager.open(childPath).getHeader().parentSession, branch);
    }
    console.log(`${kind} ${mode.toUpperCase()}_PASS`);
  } finally {
    spawnSync('tmux', ['-L', socket, 'kill-session', '-t', socket]);
  }
}
await check('clone', 'empty');
await check('clone-window', 'empty');
await check('clone', 'profile');
await check('clone-window', 'profile');
await check('clone', 'named');
await check('clone', 'child');
await check('clone', 'archived-child');
await check('fork', 'fork');
await check('fork-window', 'fork');
console.log('CLONE_LINEAGE_PASS');
