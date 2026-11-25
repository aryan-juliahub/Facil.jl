// usage: node clients.mjs <plain_port> <tls_port|0> <seconds>
// Runs WebSocket echo clients, upload clients and /big readers against the mixed
// server for <seconds>, verifying every reply. Prints one JSON line of counts.
import http from 'node:http';
import https from 'node:https';
import crypto from 'node:crypto';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const WebSocket = require('ws');

const [plain, tls, secs] = process.argv.slice(2).map(Number);
const until = Date.now() + secs * 1000;
const stats = { ws_msgs: 0, uploads: 0, bigs: 0, errors: 0, mismatches: 0, first_error: null };
const fail = (kind, e) => { stats.errors++; if (!stats.first_error) stats.first_error = `${kind}: ${e}`; };

function fnv(buf) {
  let h = 0xcbf29ce484222325n;
  for (const b of buf) h = BigInt.asUintN(64, (h ^ BigInt(b)) * 0x100000001b3n);
  return h.toString(16).padStart(16, '0');
}
const pool = crypto.randomBytes(5 << 20);
const slice = (n) => { const o = Math.floor(Math.random() * (pool.length - n)); return pool.subarray(o, o + n); };
const size = (max) => Math.max(1, Math.floor(Math.exp(Math.random() * Math.log(max))));

function wsClient(url) {
  return new Promise((resolve) => {
    const ws = new WebSocket(url, { rejectUnauthorized: false, maxPayload: 8 << 20 });
    let expect = null;
    const next = () => {
      if (Date.now() > until) { ws.close(1000); return; }
      const text = Math.random() < 0.3;
      const n = size(300 << 10);
      expect = text ? Buffer.from('t'.repeat(n)) : Buffer.from(slice(n));
      ws.send(text ? expect.toString() : expect, { binary: !text });
    };
    ws.on('open', next);
    ws.on('message', (data) => {
      if (!Buffer.from(data).equals(expect)) stats.mismatches++;
      stats.ws_msgs++;
      next();
    });
    ws.on('error', (e) => fail('ws', e.message));
    ws.on('close', () => resolve());
  });
}

const agentPlain = new http.Agent({ keepAlive: true, maxSockets: 64 });
const agentTls = new https.Agent({ keepAlive: true, maxSockets: 64, rejectUnauthorized: false });
function request(secure, port, opts, body) {
  return new Promise((resolve, reject) => {
    const mod = secure ? https : http;
    const req = mod.request({ host: '127.0.0.1', port, agent: secure ? agentTls : agentPlain, ...opts }, (res) => {
      const parts = [];
      res.on('data', (c) => parts.push(c));
      res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(parts) }));
      res.on('error', reject);
    });
    req.setTimeout(30000, () => req.destroy(new Error('timeout')));
    req.on('error', reject);
    if (body) {
      if (opts.chunked) {
        for (let o = 0; o < body.length; o += 65536) req.write(body.subarray(o, o + 65536));
      } else req.write(body);
    }
    req.end();
  });
}

async function uploader(secure, port) {
  while (Date.now() < until) {
    const body = slice(size(4 << 20));
    const chunked = Math.random() < 0.33;
    const headers = chunked ? { 'transfer-encoding': 'chunked' } : { 'content-length': body.length };
    try {
      const r = await request(secure, port, { method: 'POST', path: '/upload', headers, chunked }, body);
      if (r.status !== 200 || r.body.toString() !== `${body.length} ${fnv(body)}`) stats.mismatches++;
      stats.uploads++;
    } catch (e) { fail('upload', e.message); }
  }
}

const BIG = Buffer.alloc(1 << 20, 'x');
for (let i = 0; i < BIG.length; i += 4096) BIG[i] = 97 + ((i / 4096) % 26);
async function bigReader(secure, port) {
  while (Date.now() < until) {
    const path = Math.random() < 0.5 ? '/big' : '/big2';
    try {
      const r = await request(secure, port, { method: 'GET', path });
      if (r.status !== 200 || !r.body.equals(BIG)) stats.mismatches++;
      stats.bigs++;
    } catch (e) { fail('big', e.message); }
  }
}

const jobs = [];
const ports = [[false, plain]];
if (tls) ports.push([true, tls]);
for (const [secure, port] of ports) {
  const scheme = secure ? 'wss' : 'ws';
  for (let i = 0; i < 8; i++) jobs.push(wsClient(`${scheme}://127.0.0.1:${port}/ws`));
  for (let i = 0; i < 4; i++) jobs.push(uploader(secure, port));
  for (let i = 0; i < 4; i++) jobs.push(bigReader(secure, port));
}
await Promise.all(jobs);
console.log(JSON.stringify(stats));
process.exit(0);
