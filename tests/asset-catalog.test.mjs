import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve, dirname } from 'node:path';
import assert from 'node:assert/strict';
import test from 'node:test';

const root = fileURLToPath(new URL('../', import.meta.url));
const catalog = JSON.parse(readFileSync(resolve(root, 'assets/catalog.json'), 'utf8'));

test('private file catalog pins artifacts without credentials or OCI machinery', () => {
  assert.equal(catalog.schemaVersion, 1);
  assert.equal(catalog.hosting, 'private-file-server');
  const url = new URL(catalog.baseUrl);
  assert.equal(url.protocol, 'https:');
  assert.equal(url.username + url.password + url.search + url.hash, '');
  assert.match(catalog.caCertificateFingerprintSha256, /^[A-F0-9]{64}$/);
  assert.equal(catalog.remoteManifest, 'asset-manifest.json');
  for (const asset of Object.values(catalog.assets)) {
    assert.match(asset.file, /^[a-z0-9.-]+$/);
    assert.ok(Number.isSafeInteger(asset.bytes) && asset.bytes > 0);
    assert.match(asset.sha256, /^[a-f0-9]{64}$/);
    assert.match(asset.testContractCommit, /^[a-f0-9]{40}$/);
    assert.ok(asset.cases.length > 0);
    for (const id of asset.cases) assert.ok(existsSync(resolve(root, 'cases', id, 'cmd')));
  }
  assert.equal(catalog.assets['macos-gui'].crossMacVerified, false);
  assert.equal(catalog.assets['linux-vmspawn'].fullTenCaseSuiteVerified, false);
  assert.match(catalog.assets['macos-gui'].guestHostKey, /^ssh-ed25519 [A-Za-z0-9+/=]+$/);
  assert.ok(existsSync(resolve(root, catalog.assets['macos-gui'].guestAgentRecipe)));
});

test('discovery is reachable from agent and human entry points; local doc links resolve', () => {
  for (const file of ['README.md', 'AGENTS.md']) {
    const contents = readFileSync(resolve(root, file), 'utf8');
    assert.match(contents, /bin\/locate-assets\.sh/);
    assert.match(contents, /docs\/assets\.md/);
  }
  for (const file of ['README.md', 'docs/assets.md', 'docs/macos-tart.md', 'docs/macos-gui-seed.md']) {
    const contents = readFileSync(resolve(root, file), 'utf8');
    for (const match of contents.matchAll(/\]\(([^)]+)\)/g)) {
      const target = match[1].split('#')[0];
      if (!target || target.includes('://')) continue;
      assert.ok(existsSync(resolve(root, dirname(file), target)), `${file}: missing ${target}`);
    }
  }
});
