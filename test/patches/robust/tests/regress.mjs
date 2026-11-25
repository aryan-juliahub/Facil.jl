// usage: node regress.mjs <port>     Functional regression pass (server started with MAXBODY=64).
import net from 'node:net';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import http from 'node:http';
const port = +process.argv[2];
const here = path.dirname(new URL(import.meta.url).pathname);
let fail = 0;
const say = (ok, label, extra = '') => { if (!ok) fail++; console.log(`${ok ? 'ok  ' : 'FAIL'} ${label}${extra ? ' — ' + extra : ''}`); };
const raw = (payload, ms = 1200) => new Promise((res) => { const s = net.connect(port, '127.0.0.1'); let buf = Buffer.alloc(0);
  s.on('connect', () => s.write(payload)); s.on('data', (d) => { buf = Buffer.concat([buf, d]); }); s.on('error', () => {});
  setTimeout(() => { s.destroy(); res(buf.toString('latin1')); }, ms); });
const count = (t) => [...t.matchAll(/HTTP\/1\.1 (\d{3})/g)].map((m) => +m[1]);
const sha = (b) => crypto.createHash('sha256').update(b).digest('hex');

let t = await raw('GET /json HTTP/1.1\r\nHost: x\r\n\r\n');
say(count(t)[0] === 200 && t.includes('"name":"alice"'), 'GET /json');
const body = crypto.randomBytes(300000);
t = await raw(Buffer.concat([Buffer.from(`POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: ${body.length}\r\n\r\n`), body]));
say(t.includes(sha(body)), 'POST 300 KB, sha256 echoed');
const cb = crypto.randomBytes(70000);
t = await raw(Buffer.concat([Buffer.from('POST /upload HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n'), Buffer.from(cb.length.toString(16) + '\r\n'), cb, Buffer.from('\r\n0\r\n\r\n')]));
say(t.includes(sha(cb)), 'POST chunked 70 KB, sha256 echoed');
// keep-alive: 20 sequential requests on one socket
{ const agent = new http.Agent({ keepAlive: true, maxSockets: 1 }); let ok = 0; const socks = new Set();
  for (let i = 0; i < 20; i++) await new Promise((r) => http.get({ port, host: '127.0.0.1', path: '/json', agent }, (res) => { socks.add(res.socket); res.resume(); res.on('end', () => { if (res.statusCode === 200) ok++; r(); }); }));
  agent.destroy(); say(ok === 20 && socks.size === 1, 'keep-alive: 20 requests on one connection', `${ok} ok on ${socks.size} socket(s)`); }
t = await raw('GET /json HTTP/1.1\r\nHost: x\r\n\r\n'.repeat(3));
say(JSON.stringify(count(t)) === '[200,200,200]', 'pipelining x3', JSON.stringify(count(t)));
t = await raw('GET /json HTTP/1.1\r\nHost: x\r\n\r\n'.repeat(40));
say(count(t).length === 40 && count(t).every((x) => x === 200), 'pipelining x40', `${count(t).length} replies`);
t = await raw('GET /big HTTP/1.1\r\nHost: x\r\n\r\n'.repeat(6), 4000);
say(count(t).length === 6 && t.length > 6 * (1 << 20), 'pipelining x6 of a 1 MB response', `${count(t).length} replies, ${t.length} bytes`);
t = await raw('POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhelloGET /json HTTP/1.1\r\nHost: x\r\n\r\n');
say(JSON.stringify(count(t)) === '[200,200]', 'POST then GET pipelined', JSON.stringify(count(t)));
t = await raw('HEAD /json HTTP/1.1\r\nHost: x\r\n\r\nGET /json HTTP/1.1\r\nHost: x\r\n\r\n');
say(JSON.stringify(count(t)) === '[200,200]' && t.split('\r\n\r\n')[1].startsWith('HTTP/1.1'), 'HEAD has headers only, next request intact');
t = await raw('HEAD /a.txt HTTP/1.1\r\nHost: x\r\n\r\n');
say(count(t)[0] === 200 && /content-length:24/.test(t) && t.split('\r\n\r\n')[1] === '', 'HEAD on a static file');
t = await raw('GET /json HTTP/1.0\r\nHost: x\r\n\r\n');
say(count(t)[0] === 200 && /connection:close/.test(t), 'HTTP/1.0 request closes');
t = await raw('GET /nope HTTP/1.1\r\nHost: x\r\n\r\n');
say(count(t)[0] === 404, '404 for unknown path');
// big transfers, streamed so nothing large sits in this process
const big = path.join(here, '..', 'public', 'big_100m.bin'), up = path.join(here, '..', 'logs', 'up_50m.bin');
const fileSha = (f) => new Promise((r) => { const h = crypto.createHash('sha256'); fs.createReadStream(f).on('data', (d) => h.update(d)).on('end', () => r(h.digest('hex'))); });
if (fs.existsSync(big)) {
  const want = await fileSha(big);
  const got = await new Promise((r) => http.get({ port, host: '127.0.0.1', path: '/big_100m.bin' }, (res) => { const h = crypto.createHash('sha256'); let n = 0; res.on('data', (d) => { h.update(d); n += d.length; }); res.on('end', () => r([res.statusCode, n, h.digest('hex')])); }));
  say(got[0] === 200 && got[2] === want, '100 MB static download, sha256 matches', `${got[1]} bytes`);
  const part = await new Promise((r) => http.get({ port, host: '127.0.0.1', path: '/big_100m.bin', headers: { Range: 'bytes=50000000-' } }, (res) => { let n = 0; res.on('data', (d) => { n += d.length; }); res.on('end', () => r([res.statusCode, n])); }));
  say(part[0] === 206 && part[1] === fs.statSync(big).size - 50000000, '100 MB file, Range bytes=50000000-', `${part[0]}, ${part[1]} bytes`);
}
if (fs.existsSync(up)) {
  const want = await fileSha(up); const size = fs.statSync(up).size;
  const got = await new Promise((r) => { const q = http.request({ port, host: '127.0.0.1', path: '/upload', method: 'POST', headers: { 'Content-Length': size } }, (res) => { let b = ''; res.on('data', (d) => { b += d; }); res.on('end', () => r(b)); }); fs.createReadStream(up).pipe(q); });
  say(got.includes(want) && got.includes(`len=${size}`), '50 MB upload, sha256 matches', got.trim().slice(0, 40));
}
console.log(`failures: ${fail}`);
process.exit(0);
