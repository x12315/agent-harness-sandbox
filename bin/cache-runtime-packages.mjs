#!/usr/bin/env node
/** Prepare a dedicated public npm tarball cache for offline guest installation; never install or execute target packages on the host. */
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, readFile, realpath, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const [platform, arch, destination] = process.argv.slice(2);
if (!['darwin', 'linux'].includes(platform) || !['arm64', 'x64'].includes(arch) || !destination) throw Error('usage: cache-runtime-packages.mjs <darwin|linux> <arm64|x64> <outside-repository-cache>');
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const output = resolve(destination);
if (output === root || output.startsWith(root + '/')) throw Error('runtime caches must stay outside the repository');
const lockBytes = await readFile(join(root, 'image-deps/package-lock.json'));
const lock = JSON.parse(lockBytes);
const packages = new Map();
for (const entry of Object.values(lock.packages)) {
  if (!entry.resolved || entry.link) continue;
  if (entry.os && !entry.os.includes(platform) || entry.cpu && !entry.cpu.includes(arch)) continue;
  const url = new URL(entry.resolved);
  if (url.origin !== 'https://registry.npmjs.org' || url.username || url.password || url.search || url.hash || !url.pathname.endsWith('.tgz') || !/^sha512-[A-Za-z0-9+/]+=*$/.test(entry.integrity ?? '')) throw Error('runtime cache requires public registry tarballs with integrity and no credentials/query parameters');
  packages.set(entry.resolved, entry.integrity);
}
const npmCli = await realpath(execFileSync('which', ['npm'], { encoding: 'utf8' }).trim());
const require = createRequire(npmCli);
const cacache = require('cacache');
const pacote = require('pacote');
const source = execFileSync('npm', ['config', 'get', 'cache'], { encoding: 'utf8', timeout: 5000 }).trim() + '/_cacache';
await mkdir(output, { recursive: true });
let completed = 0;
let downloaded = 0;
const queue = [...packages];
await Promise.all(Array.from({ length: 4 }, async () => {
  while (queue.length) {
    const [url, integrity] = queue.shift();
    let bytes;
    try { bytes = await cacache.get.byDigest(join(output, '_cacache'), integrity); }
    catch {
      try { bytes = await cacache.get.byDigest(source, integrity); }
      catch {
        bytes = await pacote.tarball(url, { cache: join(output, '_cacache'), integrity, fetchRetries: 0, fetchTimeout: 15000 });
        downloaded++;
      }
    }
    await cacache.put(join(output, '_cacache'), `pacote:tarball:${url}`, bytes, { integrity });
    // Published shrinkwraps can omit integrity and use npm's HTTP cache instead.
    const responseKey = `make-fetch-happen:request-cache:${url}`;
    const response = await cacache.get.info(join(output, '_cacache'), responseKey) || await cacache.get.info(source, responseKey);
    if (response?.metadata) {
      const metadata = response.metadata;
      const resHeaders = Object.fromEntries(Object.entries(metadata.resHeaders ?? {}).filter(([key]) => ['cache-control', 'date', 'etag', 'last-modified', 'content-type', 'content-length'].includes(key)));
      await cacache.put(join(output, '_cacache'), responseKey, bytes, { integrity, metadata: { time: metadata.time, url, reqHeaders: {}, resHeaders, options: { compress: true } } });
    } else {
      const responseBytes = await pacote.tarball(url, { cache: join(output, '_cacache'), fetchRetries: 0, fetchTimeout: 15000 });
      await cacache.put(join(output, '_cacache'), `pacote:tarball:${url}`, responseBytes, { integrity });
      downloaded++;
    }
    completed++;
    if (completed % 50 === 0 || completed === packages.size) console.log(`runtime-cache ${completed}/${packages.size} downloaded=${downloaded}`);
  }
}));
await writeFile(join(output, 'runtime-cache.json'), JSON.stringify({ platform, arch, lockSha256: createHash('sha256').update(lockBytes).digest('hex'), packages: packages.size, downloaded }, null, 2) + '\n');
console.log(`runtime cache ready: ${output}`);
