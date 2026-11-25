// HTTPS test client. Usage: node client.js '<json spec>'; prints one line per
// request: key=value fields separated by tabs (error=<code> on failure).
// spec: {port, servername?, tls: {...tls.connect options, file paths in ca/cert/key},
//        requests: [{method, path, size?}], keepalive?, parallel?}
const https = require('https');
const crypto = require('crypto');
const fs = require('fs');

const spec = JSON.parse(process.argv[2]);
const opts = Object.assign({}, spec.tls || {});
for (const k of ['ca', 'cert', 'key']) if (opts[k]) opts[k] = fs.readFileSync(opts[k]);
if (!opts.ca) opts.rejectUnauthorized = false;
opts.checkServerIdentity = () => undefined;
const agent = new https.Agent(Object.assign({ keepAlive: !!spec.keepalive, maxSockets: spec.parallel ? Infinity : 1 }, opts));

function pattern(n) {
  const b = Buffer.allocUnsafe(n);
  for (let i = 0; i < n; i++) b[i] = (i * 7 + (i >>> 10)) & 0xff;
  return b;
}
const sha = (b) => crypto.createHash('sha256').update(b).digest('hex');
const sockets = new Map();

function one(r) {
  return new Promise((resolve) => {
    const body = r.size !== undefined ? pattern(r.size) : null;
    const req = https.request({
      host: '127.0.0.1', port: spec.port, method: r.method || 'GET', path: r.path, agent,
      servername: spec.servername, headers: body ? { 'content-length': body.length } : {},
    }, (res) => {
      const chunks = [];
      const s = res.socket;
      if (!sockets.has(s)) sockets.set(s, sockets.size);
      const peer = s.getPeerCertificate();
      const info = { protocol: s.getProtocol(), cipher: s.getCipher().name, alpn: s.alpnProtocol || '-' };
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        const got = Buffer.concat(chunks);
        const want = r.expect !== undefined ? sha(pattern(r.expect)) : (body ? sha(body) : null);
        const subj = (peer && peer.subject) || {};
        resolve({
          status: res.statusCode, len: got.length, intact: want ? sha(got) === want : 'na',
          clen: res.headers['content-length'] || '-', socket: sockets.get(s),
          protocol: info.protocol, cipher: info.cipher, alpn: info.alpn,
          cn: subj.CN || '-', org: subj.O || '-', body: got.length <= 64 ? got.toString() : '-',
        });
      });
    });
    req.on('error', (e) => resolve({ error: e.code || String(e) }));
    if (body) req.end(body); else req.end();
  });
}

// WebSocket echo over TLS: spec.ws = {path, count, size}. Sends every message
// at once and checks each comes back intact, in any order.
function wsEcho(w) {
  return new Promise((resolve) => {
    const tls = require('tls');
    const s = tls.connect({ host: '127.0.0.1', port: spec.port, rejectUnauthorized: false });
    const want = new Map();
    let buf = Buffer.alloc(0), upgraded = false, ok = 0, bad = 0;
    let timer = null;
    const done = (extra) => { clearTimeout(timer); s.destroy(); resolve(Object.assign({ ws_ok: ok, ws_bad: bad }, extra || {})); };
    s.on('secureConnect', () => s.write(`GET ${w.path} HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n` +
      `Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n`));
    s.on('data', (d) => {
      buf = Buffer.concat([buf, d]);
      if (!upgraded) {
        const i = buf.indexOf('\r\n\r\n');
        if (i < 0) return;
        if (!buf.subarray(0, i).toString().startsWith('HTTP/1.1 101')) return done({ error: 'no-upgrade' });
        upgraded = true;
        buf = buf.subarray(i + 4);
        const frames = [];
        for (let k = 0; k < w.count; k++) {
          const p = pattern(w.size);
          p.writeUInt32LE(k, 0);
          want.set(sha(p), true);
          const n = p.length;
          const head = n < 126 ? Buffer.from([0x82, 0x80 | n]) : n < 65536 ? Buffer.from([0x82, 0xfe, n >> 8, n & 255])
            : (() => { const h = Buffer.alloc(10); h[0] = 0x82; h[1] = 0xff; h.writeBigUInt64BE(BigInt(n), 2); return h; })();
          frames.push(head, Buffer.alloc(4), p);
        }
        s.write(Buffer.concat(frames));
      }
      for (;;) {
        if (buf.length < 2) return;
        let n = buf[1] & 127, off = 2;
        if (n === 126) { if (buf.length < 4) return; n = buf.readUInt16BE(2); off = 4; }
        else if (n === 127) { if (buf.length < 10) return; n = Number(buf.readBigUInt64BE(2)); off = 10; }
        if (buf.length < off + n) return;
        const h = sha(buf.subarray(off, off + n));
        want.delete(h) ? ok++ : bad++;
        buf = buf.subarray(off + n);
        if (ok + bad === w.count) return done();
      }
    });
    s.on('error', (e) => done({ error: e.code || String(e) }));
    timer = setTimeout(() => done({ error: 'timeout' }), 30000);
  });
}

// A TCP connection that starts its handshake only after spec.late ms.
function late(ms) {
  return new Promise((resolve) => {
    const net = require('net'), tls = require('tls');
    const raw = net.connect(spec.port, '127.0.0.1');
    raw.on('error', (e) => resolve({ error: e.code || String(e) }));
    raw.on('connect', () => setTimeout(() => {
      const s = tls.connect({ socket: raw, rejectUnauthorized: false });
      let got = '';
      s.on('secureConnect', () => s.write('GET /hello HTTP/1.1\r\nHost: x\r\n\r\n'));
      s.on('data', (d) => { got += d; });
      s.on('error', (e) => resolve({ error: e.code || String(e) }));
      s.on('close', () => resolve(got ? { reply: got.split('\r\n')[0].replace(/ /g, '_') } : { error: 'closed' }));
    }, ms));
  });
}

(async () => {
  if (spec.late) {
    const r = await late(spec.late);
    console.log(Object.entries(r).map(([k, v]) => k + '=' + v).join('\t'));
    return;
  }
  if (spec.ws) {
    const r = await wsEcho(spec.ws);
    console.log(Object.entries(r).map(([k, v]) => k + '=' + v).join('\t'));
    return;
  }
  const reqs = spec.requests;
  const out = spec.parallel ? await Promise.all(reqs.map(one)) : [];
  if (!spec.parallel) for (const r of reqs) out.push(await one(r));
  for (const r of out) console.log(Object.entries(r).map(([k, v]) => k + '=' + v).join('\t'));
  agent.destroy();
})();
