// usage: node deflate_check.mjs <port>
// permessage-deflate against the `ws` client (context takeover offered and refused, and
// no_context_takeover requested) and a browser-style offer; checks RSV1 on the wire and the echo.
import { createRequire } from 'node:module';
import net from 'node:net';
import zlib from 'node:zlib';
const require = createRequire(import.meta.url);
const WS = require('ws');
const port = +process.argv[2];
let pass = 0, fail = 0;
const ok = (n, c, e = '') => { c ? pass++ : fail++; console.log(`${c ? 'PASS' : 'FAIL'} ${n} ${e}`); };
const json = JSON.stringify({ items: Array.from({ length: 40 }, (_, i) => ({ id: i, name: `user-${i}`, email: `user${i}@example.com`, active: i % 2 === 0, score: i * 3.5, tags: ['alpha', 'beta', 'gamma'] })) });
for (const [label, opts] of [['ws default offer (client_max_window_bits)', true], ['ws clientNoContextTakeover', { clientNoContextTakeover: true, serverNoContextTakeover: true }], ['ws threshold 0', { threshold: 0 }]]) {
  const ws = new WS(`ws://127.0.0.1:${port}/echo`, { perMessageDeflate: opts });
  await new Promise((r, j) => { ws.on('open', r); ws.on('error', j); });
  const prm = (ws._extensions['permessage-deflate'] || {}).params || {};
  ok(`${label}: negotiated without context takeover`, /permessage-deflate/.test(ws.extensions) && prm.server_no_context_takeover === true && prm.client_no_context_takeover === true, JSON.stringify(prm));
  let bad = 0;
  for (let i = 0; i < 200; i++) {
    const m = i % 5 === 4 ? Buffer.from(json + i) : json + i;      // the same text again and again: a kept window would show
    ws.send(m);
    const r = await new Promise((res) => ws.once('message', (d, b) => res({ d, b })));
    if (r.d.toString() !== m.toString() || r.b !== (i % 5 === 4)) bad++;
  }
  ok(`${label}: 200 compressed round trips intact`, bad === 0, `bad=${bad}`);
  const big = 'lorem ipsum dolor sit amet '.repeat(150000); ws.send(big);
  const r = await new Promise((res) => ws.once('message', (d) => res(d.toString())));
  ok(`${label}: 4 MB compressible text`, r === big);
  ws.send('part-1 '.repeat(500), { fin: false }); ws.send('part-2 '.repeat(500), { fin: false }); ws.send('part-3', { fin: true });
  const f = await new Promise((res) => ws.once('message', (d) => res(d.toString())));
  ok(`${label}: fragmented compressed message`, f === 'part-1 '.repeat(500) + 'part-2 '.repeat(500) + 'part-3');
  const c = new Promise((res) => ws.once('close', (code) => res(code))); ws.close(1000); ok(`${label}: clean close`, (await c) === 1000);
}
// Browser-style offer over a raw socket; looks at the bytes on the wire.
await new Promise((done) => {
  const s = net.connect(port, '127.0.0.1');
  let buf = Buffer.alloc(0), up = false;
  const frame = (payload, rsv1) => {
    const key = Buffer.from([9, 8, 7, 6]); const body = Buffer.from(payload); for (let i = 0; i < body.length; i++) body[i] ^= key[i & 3];
    const head = body.length < 126 ? Buffer.from([0x81 | (rsv1 ? 0x40 : 0), 0x80 | body.length]) : Buffer.from([0x81 | (rsv1 ? 0x40 : 0), 0x80 | 126, body.length >> 8, body.length & 255]);
    return Buffer.concat([head, key, body]);
  };
  s.on('connect', () => s.write('GET /echo HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Extensions: permessage-deflate; client_max_window_bits\r\n\r\n'));
  s.on('data', (d) => {
    buf = Buffer.concat([buf, d]);
    if (!up) {
      const i = buf.indexOf('\r\n\r\n'); if (i < 0) return;
      const head = buf.subarray(0, i).toString(); up = true; buf = buf.subarray(i + 4);
      ok('browser-style offer: response accepts permessage-deflate without context takeover', /sec-websocket-extensions:\s*permessage-deflate; server_no_context_takeover; client_no_context_takeover/i.test(head), (head.match(/sec-websocket-extensions.*/i) || [''])[0]);
      const z = zlib.deflateRawSync(json, { finishFlush: zlib.constants.Z_SYNC_FLUSH }); // ends with 00 00 ff ff
      s.write(frame(z.subarray(0, z.length - 4), true));
      return;
    }
    if (buf.length < 4) return;
    const len = (buf[1] & 127) === 126 ? buf.readUInt16BE(2) : buf[1] & 127, h = (buf[1] & 127) === 126 ? 4 : 2;
    if (buf.length < h + len) return;
    const rsv1 = (buf[0] & 0x40) !== 0;
    const out = zlib.inflateRawSync(Buffer.concat([buf.subarray(h, h + len), Buffer.from([0, 0, 0xff, 0xff])]), { finishFlush: zlib.constants.Z_SYNC_FLUSH }).toString();
    ok('raw compressed frame: reply has RSV1 and inflates to the message', rsv1 && out === json, `payload ${json.length} B -> ${len} B on the wire`);
    s.destroy(); done();
  });
});
console.log(`SUMMARY deflate port ${port}: ${pass} passed, ${fail} failed`);
process.exit(0);
