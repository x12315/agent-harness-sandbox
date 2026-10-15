#!/usr/bin/env node
/** Validate consumer tool requirements and check the actual guest runtime without installing anything. */
import { execFileSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, realpathSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { createRequire } from 'node:module';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

export const TOOL_PACKAGES = {
  pi: '@earendil-works/pi-coding-agent',
  'pi-web-ui': 'pi-web-ui',
  'agent-browser': 'agent-browser',
  claude: '@anthropic-ai/claude-code',
};

/** Requirements are a nonempty tool-to-exact-version map; arbitrary commands and version ranges are rejected. */
export function parseRequirements(text) {
  const value = JSON.parse(text);
  if (!value || Array.isArray(value) || typeof value !== 'object' || !Object.keys(value).length) throw Error('requires.json must be a nonempty tool/version map');
  for (const [tool, version] of Object.entries(value)) {
    if (!Object.hasOwn(TOOL_PACKAGES, tool) || typeof version !== 'string' || !/^\d+\.\d+\.\d+(?:-[a-zA-Z0-9.-]+)?$/.test(version)) {
      throw Error(`unsupported tool or non-exact version in requires.json: ${tool}`);
    }
  }
  return value;
}

/** Check package versions, real CLI entrypoints and, for WebUI, a working native PTY; returns non-secret evidence. */
export async function checkRuntime(requirements, root) {
  const modules = existsSync(join(root, 'lib/node_modules')) ? join(root, 'lib/node_modules') : join(root, 'node_modules');
  const tools = {};
  const versionProbeMs = {};
  for (const [tool, expected] of Object.entries(requirements)) {
    const dir = join(modules, TOOL_PACKAGES[tool]);
    const file = join(dir, 'package.json');
    if (!existsSync(file)) throw Error(`missing ${tool}@${expected}; prepare a separate runtime base with the producer's Linux image or Tart preparation entrypoint, then select that base`);
    const pkg = JSON.parse(readFileSync(file, 'utf8'));
    if (pkg.version !== expected) throw Error(`${tool}: expected ${expected}, installed ${pkg.version}; no automatic upgrade`);
    const bin = typeof pkg.bin === 'string' ? pkg.bin : pkg.bin?.[tool];
    if (!bin) throw Error(`${tool}: missing CLI entrypoint`);
    const entry = join(dir, bin);
    const executable = readFileSync(entry).subarray(0, 2).toString() === '#!' ? process.execPath : entry;
    const args = executable === process.execPath ? [entry, '--version'] : ['--version'];
    let actual;
    const started = Date.now();
    console.error(`runtime-check tool=${tool}`);
    const probe = mkdtempSync(join(tmpdir(), 'ahsb-version-'));
    try {
      actual = execFileSync(executable, args, { cwd: probe, env: { ...process.env, PI_CODING_AGENT_DIR: probe, PI_OFFLINE: '1' }, timeout: 30000, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
    } catch (error) { throw Error(`${tool}: real CLI probe failed (${error.code || error.status || 'unknown'}) or exceeded 30 seconds`); }
    finally { rmSync(probe, { recursive: true, force: true }); }
    const versionToken = new RegExp(`(^|[^0-9A-Za-z.-])v?${expected.replaceAll('.', '\\.')}(?=$|[^0-9A-Za-z.-])`);
    if (!versionToken.test(actual)) throw Error(`${tool}: real CLI version does not match ${expected}`);
    tools[tool] = expected;
    versionProbeMs[tool] = Date.now() - started;
  }
  let nativePty = false;
  if (requirements['pi-web-ui']) {
    const require = createRequire(join(modules, 'pi-web-ui/package.json'));
    const pty = require('node-pty');
    await new Promise((accept, reject) => {
      let output = '';
      const child = pty.spawn(process.execPath, ['-e', 'process.stdout.write("ahsb-pty-ok")'], { cwd: root, env: process.env });
      const timer = setTimeout(() => { child.kill(); reject(Error('native PTY timed out')); }, 5000);
      child.onData(data => { output += data; });
      child.onExit(({ exitCode }) => {
        clearTimeout(timer);
        if (exitCode !== 0 || !output.includes('ahsb-pty-ok')) reject(Error('native PTY failed'));
        else accept();
      });
    });
    nativePty = true;
  }
  return { ok: true, platform: process.platform, arch: process.arch, node: process.version, nodeAbi: process.versions.modules, tools, versionProbeMs, nativePty };
}

if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) {
  try {
    const [mode, file, root] = process.argv.slice(2);
    const requirements = parseRequirements(readFileSync(file, 'utf8'));
    if (mode === '--validate') process.exit(0);
    if (mode !== '--check' || !root) throw Error('usage: guest-runtime.mjs --validate <requires.json> | --check <requires.json> <runtime-root>');
    console.log(JSON.stringify(await checkRuntime(requirements, root)));
  } catch (error) {
    console.log(JSON.stringify({ ok: false, error: error.message }));
    console.error(`guest runtime not ready: ${error.message}`);
    process.exitCode = 78;
  }
}
