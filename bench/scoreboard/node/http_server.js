// node:http opponent for every plain-HTTP scoreboard row. Routes match facil/server.jl.
//   node http_server.js <port>        env WORKERS=N runs node:cluster (round-robin) with N workers
const http = require('http');
const cluster = require('cluster');
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const PORT = parseInt(process.argv[2], 10);
const WORKERS = parseInt(process.env.WORKERS || '1', 10);
const SMALL_JSON = '{"id":1,"name":"alice","email":"alice@example.com","tags":["admin","reviewer"],"created_at":"2024-01-01T12:00:00Z","status":"active","login_count":42}';

if (cluster.isPrimary && WORKERS > 1) {
  cluster.schedulingPolicy = cluster.SCHED_RR;
  let up = 0;
  for (let i = 0; i < WORKERS; i++)
    cluster.fork().on('message', () => { if (++up === WORKERS) console.log(`READY pid=${process.pid} workers=${WORKERS}`); });
  return;
}

const bufs = new Map();
const xbuf = (n) => { let b = bufs.get(n); if (!b) bufs.set(n, b = Buffer.alloc(n, 'x')); return b; };

const FNV_BUF = Buffer.alloc(16384);
for (let i = 1; i <= 16384; i++) FNV_BUF[i - 1] = (i * 31 + 7) & 255;
function fnv16k(seed) {
  let h = (0x811c9dc5 ^ seed) | 0;
  for (let p = 0; p < 3; p++)
    for (let i = 0; i < 16384; i++) h = Math.imul(h ^ FNV_BUF[i], 0x01000193);
  return (h >>> 0).toString(16);
}
const FLOATS = new Float64Array(100000);
for (let i = 0; i < FLOATS.length; i++) FLOATS[i] = (i + 1) * 0.5;
function floatSum() { let s = 0; for (let i = 0; i < FLOATS.length; i++) s += FLOATS[i]; return s; }
const HASH_INPUT = new Uint8Array(4096);
for (let i = 0; i < 4096; i++) HASH_INPUT[i] = ((i + 1) * 31 + 7) % 251;
function fnv4k() { let h = 0x811c9dc5 | 0; for (let i = 0; i < 4096; i++) h = Math.imul(h ^ HASH_INPUT[i], 0x01000193); return h >>> 0; }
function genDoc(n) {
  const items = new Array(n);
  for (let i = 1; i <= n; i++)
    items[i - 1] = { id: i, name: 'user' + i, email: 'user' + i + '@example.com', active: i % 2 === 0, score: i * 1.5, tags: ['admin', 'reviewer'] };
  return JSON.stringify({ count: n, items });
}
function checksum(b, offset) {
  let s = 0;
  for (let i = (1024 - offset % 1024) % 1024; i < b.length; i += 1024) s += b[i];
  return s;
}
let sink;
function garbage(n) { const g = new Uint8Array(n); g[0] = 1; g[n - 1] = 2; sink = g; }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const DATA = path.join(__dirname, '..', 'data');
const PAYLOADS = {};
if (fs.existsSync(DATA)) for (const f of fs.readdirSync(DATA)) if (f.endsWith('.json')) PAYLOADS[path.parse(f).name] = fs.readFileSync(path.join(DATA, f));
const K = zlib.constants;
const ZOPTS = { gz: (l) => ({ level: l }), br: (l) => ({ params: { [K.BROTLI_PARAM_QUALITY]: l } }), zstd: (l) => ({ params: { [K.ZSTD_c_compressionLevel]: l } }) };
const ZAPI = {
  gz: { async: zlib.gzip, sync: zlib.gzipSync, stream: zlib.createGzip, enc: 'gzip' },
  br: { async: zlib.brotliCompress, sync: zlib.brotliCompressSync, stream: zlib.createBrotliCompress, enc: 'br' },
  zstd: { async: zlib.zstdCompress, sync: zlib.zstdCompressSync, stream: zlib.createZstdCompress, enc: 'zstd' },
};
const zroutes = new Map();
function zroute(u) {
  if (zroutes.has(u)) return zroutes.get(u);
  const p = u.split('/');
  const m = p.length === 4 && PAYLOADS[p[3]] && /^(gz|br|zstd)(\d+)(sync|stream)?$/.exec(p[2]);
  const r = m ? { mode: m[3] || 'async', api: ZAPI[m[1]], opts: ZOPTS[m[1]](+m[2]), body: PAYLOADS[p[3]],
    head: { 'content-type': 'application/json', 'content-encoding': ZAPI[m[1]].enc, vary: 'accept-encoding' } } : null;
  zroutes.set(u, r);
  return r;
}

function send(res, type, body) {
  res.writeHead(200, { 'Content-Type': type, 'Content-Length': String(Buffer.byteLength(body)) });
  res.end(body);
}
const text = (res, s) => send(res, 'text/plain', s);
const json = (res, s) => send(res, 'application/json', s);
function empty(res) { res.writeHead(200, { 'Content-Length': '0' }); res.end(); }
function notFound(res) { res.writeHead(404, { 'Content-Length': '0' }); res.end(); }
function readBody(req, cb) {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => cb(chunks.length === 1 ? chunks[0] : Buffer.concat(chunks)));
}

let seq = 0;
async function handle(req, res) {
  const url = req.url;
  switch (url) {
    case '/tiny': case '/atiny': return empty(res);
    case '/json': return json(res, SMALL_JSON);
    case '/echo':
      return readBody(req, (b) => {
        res.writeHead(200, { 'Content-Type': 'application/octet-stream', 'x-echo': req.headers['x-echo'] || 'none', 'Content-Length': String(b.length) });
        res.end(b);
      });
    case '/hdr': { const h = req.headers; return text(res, Object.keys(h).length + ' ' + (h.cookie ? h.cookie.length : 0)); }
    case '/fnv16k': return text(res, fnv16k(++seq));
    case '/floatsum': return text(res, String(floatSum()));
    case '/hash': return text(res, String(fnv4k()));
    case '/parse': return readBody(req, (b) => text(res, JSON.parse(b.toString()).name));
    case '/gen1k': return json(res, genDoc(9));
    case '/gen50k': return json(res, genDoc(440));
    case '/gc': garbage(100000); return json(res, SMALL_JSON);
    case '/gc10': garbage(10000); return json(res, SMALL_JSON);
    case '/wait1': await sleep(1); return json(res, SMALL_JSON);
    case '/wait10': await sleep(10); return json(res, SMALL_JSON);
    case '/upload': return readBody(req, (b) => text(res, b.length + ' ' + (checksum(b, 0) + (b.length ? b[b.length - 1] : 0))));
    case '/upload/stream': {
      let n = 0, s = 0, last = 0;
      req.on('data', (c) => { s += checksum(c, n); n += c.length; last = c[c.length - 1]; });
      return req.on('end', () => text(res, n + ' ' + (s + (n ? last : 0))));
    }
  }
  if (url.startsWith('/bytes/')) {
    const b = xbuf(+url.slice(7));
    res.writeHead(200, { 'Content-Type': 'application/octet-stream', 'Content-Length': String(b.length) });
    return res.end(b);
  }
  if (url.startsWith('/query?')) {
    const d = new Map(new URL(url, 'http://127.0.0.1').searchParams);
    return text(res, d.size + ' ' + (d.get('k7') || ''));
  }
  if (url.startsWith('/stream/') || url.startsWith('/pstream/')) {
    const p = url.split('/'), n = +p[2], c = xbuf(+p[3] * 1024);
    res.writeHead(200, { 'content-type': 'text/plain' });
    if (p[1] === 'stream') { for (let i = 0; i < n; i++) res.write(c); return res.end(); }
    let i = 0;
    const tick = () => { res.write(c); if (++i < n) setTimeout(tick, 1); else res.end(); };
    return setTimeout(tick, 1);
  }
  if (url.startsWith('/z/')) {
    const r = zroute(url);
    if (!r) return notFound(res);
    const out = (b) => { res.writeHead(200, { ...r.head, 'content-length': b.length }); res.end(b); };
    if (r.mode === 'sync') return out(r.api.sync(r.body, r.opts));
    if (r.mode === 'async') return r.api.async(r.body, r.opts, (e, b) => out(b));
    res.writeHead(200, r.head);
    const z = r.api.stream(r.opts);
    z.pipe(res);
    return z.end(r.body);
  }
  return notFound(res);
}

const server = http.createServer(handle);
server.on('clientError', (e, sock) => sock.destroy());
server.keepAliveTimeout = 60000;
server.listen(PORT, '127.0.0.1', () => {
  if (cluster.isWorker) process.send('up');
  else console.log(`READY pid=${process.pid}`);
});
