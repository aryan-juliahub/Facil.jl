// usage: node timeout_check.mjs <port>   (server started with WS_TIMEOUT=2)
// What an idle connection sees: pings, and whether a peer that never answers them is dropped.
import { createRequire } from 'node:module';
import net from 'node:net';
const require = createRequire(import.meta.url);
const WS = require('ws');
const port = +process.argv[2];
const ws = new WS(`ws://127.0.0.1:${port}/echo`);
let pings = 0, closedAt = null; const t0 = Date.now();
ws.on('ping', () => pings++); ws.on('close', () => { closedAt = Date.now() - t0; }); ws.on('error', () => {});
const s = net.connect(port, '127.0.0.1'); let rawPings = 0, rawEnd = null, up = false, buf = Buffer.alloc(0);
s.on('connect', () => s.write('GET /echo HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n'));
s.on('data', (d) => {
  buf = Buffer.concat([buf, d]);
  if (!up) { const i = buf.indexOf('\r\n\r\n'); if (i < 0) return; up = true; buf = buf.subarray(i + 4); }
  while (buf.length >= 2) { if ((buf[0] & 15) === 9) rawPings++; buf = buf.subarray(2 + (buf[1] & 127)); }
});
s.on('close', () => { rawEnd = Date.now() - t0; }); s.on('error', () => {});
await new Promise((r) => setTimeout(r, 9000));
console.log(`answering client (ws): ${pings} pings in 9 s, ${closedAt === null ? 'still open' : 'CLOSED after ' + closedAt + ' ms'}`);
console.log(`silent client (raw, never pongs): ${rawPings} pings, ${rawEnd === null ? 'still open after 9 s' : 'dropped after ' + rawEnd + ' ms'}`);
process.exit(0);
