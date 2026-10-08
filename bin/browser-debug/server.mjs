import http from 'node:http';
import fs from 'node:fs';
import { pathToFileURL } from 'node:url';

const page = `<!doctype html>
<html lang="en"><meta charset="utf-8"><title>Sandbox Browser Debug</title>
<style>body{font:18px sans-serif;max-width:760px;margin:40px auto}label,input,button{display:block;margin:12px 0}pre{background:#eee;padding:12px}</style>
<h1>Sandbox Browser Debug</h1>
<label>Message<input id="message"></label><button id="echo">Echo message</button><pre id="result">No message</pre>
<label>Username<input id="username" autocomplete="off"></label><button id="login">Sign in</button><pre id="session">Checking session</pre>
<a href="/second" id="second">Second page</a>
<button id="debug">Trigger diagnostics</button><pre id="diagnostics">No diagnostics</pre>
<script>
const $ = id => document.getElementById(id);
async function session() { const data=await fetch('/api/session').then(r=>r.json()); $('session').textContent=data.authenticated?'Signed in':'Signed out'; }
session();
$('echo').onclick=async()=>{const data=await fetch('/api/echo',{method:'POST',body:JSON.stringify({message:$('message').value})}).then(r=>r.json()); $('result').textContent=data.message;};
$('login').onclick=async()=>{await fetch('/api/login',{method:'POST',body:JSON.stringify({username:$('username').value})}); await session();};
$('debug').onclick=async()=>{
 console.log('sandbox-console-marker');
 setTimeout(()=>{throw new Error('sandbox-page-error-marker');},0);
 const response=await fetch('/api/unavailable');
 let dropped=false; try{await fetch('/api/drop');}catch{dropped=true;}
 $('diagnostics').textContent=JSON.stringify({status:response.status,dropped});
};
</script></html>`;

/** Create a loopback-only test fixture; onRequest receives metadata, never bodies/cookies. */
export function createFixtureServer(onRequest = () => {}) {
  return http.createServer(async (req, res) => {
    const pathname = new URL(req.url, 'http://127.0.0.1').pathname;
    const respond = (status, body, type = 'application/json', headers = {}) => {
      onRequest({ method: req.method, path: pathname, status });
      res.writeHead(status, { 'Content-Type': type, 'Cache-Control': 'no-store', ...headers });
      res.end(body);
    };
    if (pathname === '/api/drop') {
      onRequest({ method: req.method, path: pathname, dropped: true });
      req.socket.destroy();
      return;
    }
    if (pathname === '/api/session') {
      respond(200, JSON.stringify({ authenticated: /(?:^|;\s*)ahsb-session=fixture-only(?:;|$)/.test(req.headers.cookie || '') }));
      return;
    }
    if (pathname === '/api/unavailable') { respond(503, JSON.stringify({ error: 'controlled-503' })); return; }
    if (req.method === 'POST' && ['/api/echo', '/api/login'].includes(pathname)) {
      let body = '';
      for await (const chunk of req) {
        body += chunk;
        if (body.length > 4096) { respond(413, '{}'); return; }
      }
      let data;
      try { data = JSON.parse(body); } catch { respond(400, '{}'); return; }
      if (pathname === '/api/echo') { respond(200, JSON.stringify({ message: String(data.message || '') })); return; }
      if (data.username !== 'sandbox') { respond(401, '{}'); return; }
      respond(200, '{}', 'application/json', { 'Set-Cookie': 'ahsb-session=fixture-only; HttpOnly; SameSite=Strict; Path=/' });
      return;
    }
    if (pathname === '/') { respond(200, page, 'text/html; charset=utf-8'); return; }
    if (pathname === '/second') { respond(200, '<h1>Second page</h1><a href="/">Back</a>', 'text/html'); return; }
    respond(404, '{}');
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [readyFile, requestFile] = process.argv.slice(2);
  if (!readyFile || !requestFile) throw new Error('usage: server.mjs <ready-json> <request-jsonl>');
  const server = createFixtureServer(row => fs.appendFileSync(requestFile, `${JSON.stringify(row)}\n`));
  server.listen(0, '127.0.0.1', () => {
    fs.writeFileSync(readyFile, JSON.stringify({ url: `http://127.0.0.1:${server.address().port}` }));
  });
  for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => server.close());
}
