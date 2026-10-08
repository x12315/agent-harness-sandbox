import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

function values(value) {
  const result = [value];
  if (value && typeof value === 'object') {
    for (const child of Object.values(value)) result.push(...values(child));
  } else if (typeof value === 'string' && /^[\[{]/.test(value)) {
    try { result.push(...values(JSON.parse(value))); } catch {}
  }
  return result;
}

/** Assert independent browser/CDP, HTTP and artifact evidence from a completed guest run. */
export function assertBrowserEvidence(directory) {
  const text = name => fs.readFileSync(path.join(directory, name), 'utf8');
  const json = name => JSON.parse(text(name));
  const has = (name, predicate) => values(json(name)).some(predicate);
  const marker = (name, expected) => has(name, value => typeof value === 'string' && value.includes(expected));
  assert.ok(text('agent-browser-version.txt').includes('0.38.2'), 'agent-browser version is pinned');
  assert.match(text('chromium-version.txt'), /Chromium/);
  const mode = text('mode.txt').trim();
  assert.ok(['headless', 'headed'].includes(mode));
  assert.equal(text('chrome-flags.txt').includes('--headless=new'), mode === 'headless');
  assert.ok(text('chrome-flags.txt').includes('--remote-debugging-address=127.0.0.1'));
  if (mode === 'headed') {
    assert.match(text('display-number').trim(), /^\d+$/);
    assert.match(text('headed-windows.txt'), /Sandbox Browser Debug.*Chromium/, 'Chromium has an X11 window inside the guest');
  }
  const site = json('site.json');
  assert.match(site.url, /^http:\/\/127\.0\.0\.1:\d+$/);
  assert.ok(has('dom.json', value => value?.message === 'VM-only browser input' && value.session === 'Signed in' && value.diagnostics?.status === 503 && value.diagnostics.dropped === true), 'DOM reflects clicks, input, login, HTTP and transport failure');
  assert.ok(has('restored.json', value => value?.restored === true), 'new browser profile restored login');
  assert.ok(has('tabs.json', value => typeof value?.url === 'string' && value.url.endsWith('/second')), 'second tab exists');
  assert.ok(has('tabs.json', value => value?.url?.replace(/\/$/, '') === site.url), 'primary tab exists');
  assert.ok(marker('console.json', 'sandbox-console-marker'), 'console log captured');
  assert.ok(marker('errors.json', 'sandbox-page-error-marker'), 'uncaught page error captured');
  assert.ok(marker('network.json', '/api/unavailable'), 'network request captured');
  assert.match(values(json('expected-timeout.json')).filter(v => typeof v === 'string').join('\n'), /timed out|timeout.*(?:exceeded|waiting)/i, 'missing element produced a real timeout, not an unsupported-command error');
  const har = json('network.har');
  assert.ok(har.log.entries.some(row => row.request.url.endsWith('/api/unavailable') && row.response.status === 503), 'HAR contains the controlled HTTP failure');
  const trace = json('trace.json');
  assert.ok(Array.isArray(trace.traceEvents) && trace.traceEvents.length > 0, 'CDP trace contains events');
  assert.deepEqual(fs.readFileSync(path.join(directory, 'browser.png')).subarray(0, 8), Buffer.from('89504e470d0a1a0a', 'hex'), 'browser screenshot is PNG');
  const requests = text('site-requests.jsonl').trim().split('\n').map(line => JSON.parse(line));
  for (const route of ['/api/echo', '/api/login', '/api/session', '/api/unavailable', '/api/drop', '/second']) {
    assert.ok(requests.some(row => row.path === route), `fixture received ${route}`);
  }
  const summary = { mode, cdp: true, input: true, tabs: true, stateRestored: true, diagnostics: true, screenshot: true, trace: true };
  fs.writeFileSync(path.join(directory, 'summary.json'), JSON.stringify(summary, null, 2));
  return summary;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  assertBrowserEvidence(process.argv[2]);
  console.log('ok: browser actions, isolated CDP, restored state and debug artifacts verified');
}
