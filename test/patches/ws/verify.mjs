// usage: node verify.mjs <port> [quick] [deflate]
// Protocol checks against one server; prints PASS/FAIL lines and a summary. `deflate` connects the
// `ws` client with permessage-deflate on and requires the server to have accepted it.
import { createRequire } from 'node:module';
import net from 'node:net';
import crypto from 'node:crypto';
const require = createRequire(import.meta.url);
const WS = require('ws');
const port = +process.argv[2];
const quick = process.argv.includes('quick');
const deflate = process.argv.includes('deflate');
const url = `ws://127.0.0.1:${port}/echo`;
let pass = 0, fail = 0;
const ok = (name, cond, extra = '') => { cond ? pass++ : fail++; console.log(`${cond ? 'PASS' : 'FAIL'} ${name} ${extra}`); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const open = (opts = {}) => new Promise((res, rej) => {
  const ws = new WS(url, { perMessageDeflate: deflate, maxPayload: 64 << 20, ...opts });
  ws.on('open', () => res(ws)); ws.on('error', rej);
});
const next = (ws, ms = 10000) => new Promise((res, rej) => {
  const t = setTimeout(() => rej(new Error('timeout')), ms);
  ws.once('message', (data, isBinary) => { clearTimeout(t); res({ data, isBinary }); });
});
const closed = (ws, ms = 8000) => new Promise((res) => {
  const t = setTimeout(() => res({ code: 'timeout' }), ms);
  ws.once('close', (code, reason) => { clearTimeout(t); res({ code, reason: reason.toString() }); });
  ws.on('error', () => {});
});
const stats = async () => JSON.parse(await (await fetch(`http://127.0.0.1:${port}/stats`)).text());

// A raw client for frames the libraries refuse to send.
function raw() {
  return new Promise((res, rej) => {
    const s = net.connect(port, '127.0.0.1');
    let buf = Buffer.alloc(0), up = false; const frames = []; let waiter = null;
    const pump = () => {
      for (;;) {
        if (buf.length < 2) return;
        let len = buf[1] & 127, h = 2;
        if (len === 126) { if (buf.length < 4) return; len = buf.readUInt16BE(2); h = 4; }
        else if (len === 127) { if (buf.length < 10) return; len = Number(buf.readBigUInt64BE(2)); h = 10; }
        if (buf.length < h + len) return;
        frames.push({ op: buf[0] & 15, fin: buf[0] >> 7, rsv: (buf[0] >> 4) & 7, payload: buf.subarray(h, h + len) });
        buf = buf.subarray(h + len);
        if (waiter) { const w = waiter; waiter = null; w(); }
      }
    };
    const api = {
      s, frames, ended: false,
      send(op, payload, { fin = 1, mask = true, rsv = 0 } = {}) {
        payload = Buffer.from(payload);
        const head = [(fin << 7) | (rsv << 4) | op];
        const m = mask ? 0x80 : 0;
        if (payload.length < 126) head.push(m | payload.length);
        else if (payload.length < 65536) head.push(m | 126, payload.length >> 8, payload.length & 255);
        else { head.push(m | 127, 0, 0, 0, 0, (payload.length >>> 24) & 255, (payload.length >>> 16) & 255, (payload.length >>> 8) & 255, payload.length & 255); }
        const key = Buffer.from([1, 2, 3, 4]);
        const body = Buffer.from(payload);
        if (mask) for (let i = 0; i < body.length; i++) body[i] ^= key[i & 3];
        s.write(Buffer.concat(mask ? [Buffer.from(head), key, body] : [Buffer.from(head), body]));
      },
      async frame(ms = 5000) {
        const t0 = Date.now();
        while (!frames.length) {
          if (api.ended || Date.now() - t0 > ms) return null;
          await new Promise((r) => { waiter = r; setTimeout(r, 50); });
        }
        return frames.shift();
      },
      // Close status the server sent, or 'eof' when the socket just ended, or 'timeout'.
      async closeCode(ms = 6000) {
        const t0 = Date.now();
        for (;;) {
          const f = await api.frame(Math.max(1, ms - (Date.now() - t0)));
          if (!f) return api.ended ? 'eof' : 'timeout';
          if (f.op === 8) return f.payload.length >= 2 ? f.payload.readUInt16BE(0) : 'no-status';
        }
      },
    };
    s.on('connect', () => s.write(`GET /echo HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n`));
    s.on('data', (d) => {
      buf = Buffer.concat([buf, d]);
      if (!up) { const i = buf.indexOf('\r\n\r\n'); if (i < 0) return; up = true; buf = buf.subarray(i + 4); res(api); }
      pump();
    });
    s.on('end', () => { api.ended = true; if (waiter) waiter(); });
    s.on('close', () => { api.ended = true; if (waiter) waiter(); });
    s.on('error', (e) => { api.ended = true; if (!up) rej(e); });
  });
}

const t00 = Date.now();
// ---- text / binary flag
{
  const ws = await open();
  if (deflate) ok('permessage-deflate negotiated', /permessage-deflate/.test(ws.extensions), `extensions="${ws.extensions}"`);
  ws.send('héllo wörld ✓'); let r = await next(ws);
  ok('text stays text', !r.isBinary && r.data.toString() === 'héllo wörld ✓');
  const b = crypto.randomBytes(3000); ws.send(b); r = await next(ws);
  ok('binary stays binary', r.isBinary && Buffer.compare(r.data, b) === 0);
  ws.send(''); r = await next(ws);
  ok('empty text message', !r.isBinary && r.data.length === 0);
  for (const n of [125, 126, 127, 65535, 65536, 65537]) {
    const m = crypto.randomBytes(n); ws.send(m); r = await next(ws);
    if (!(r.isBinary && Buffer.compare(r.data, m) === 0)) ok(`length boundary ${n}`, false);
  }
  ok('frame-length boundaries 125..65537', true);
  // ---- fragmented message: three frames
  ws.send('part one, ', { fin: false }); ws.send('part two, ', { fin: false }); ws.send('part three', { fin: true });
  r = await next(ws);
  ok('3-frame fragmented text', !r.isBinary && r.data.toString() === 'part one, part two, part three', JSON.stringify(r.data.toString().slice(0, 40)));
  const parts = [crypto.randomBytes(70000), crypto.randomBytes(5), crypto.randomBytes(20000)];
  ws.send(parts[0], { fin: false }); ws.ping('mid'); ws.send(parts[1], { fin: false }); ws.send(parts[2], { fin: true });
  r = await next(ws);
  ok('3-frame fragmented binary with a ping in the middle', r.isBinary && Buffer.compare(r.data, Buffer.concat(parts)) === 0);
  // ---- ping / pong
  const pong = new Promise((res) => { const t = setTimeout(() => res(null), 3000); ws.once('pong', (d) => { clearTimeout(t); res(d.toString()); }); });
  ws.ping('are-you-there');
  ok('ping answered by pong with the same payload', (await pong) === 'are-you-there');
  // ---- 4 MB
  const big = crypto.randomBytes(4 << 20); ws.send(big); r = await next(ws, 30000);
  ok('4 MB binary message', r.isBinary && Buffer.compare(r.data, big) === 0, `bytes=${r.data.length}`);
  const bigText = 'ab✓'.repeat((4 << 20) / 5); ws.send(bigText); r = await next(ws, 30000);
  ok('4 MB text message', !r.isBinary && r.data.toString() === bigText);
  // ---- client-initiated close
  const c = closed(ws); ws.close(1000, 'bye'); const ev = await c;
  ok('client close(1000): `ws` client sees 1000', ev.code === 1000, `code=${ev.code}`);
}
{
  const ws = await open(); const c = closed(ws); ws.close(4321, 'custom'); const ev = await c;
  ok('client close(4321): `ws` client sees 4321', ev.code === 4321, `code=${ev.code}`);
}
{
  const ws = new WebSocket(url); await new Promise((r, j) => { ws.onopen = r; ws.onerror = j; });
  const c = new Promise((r) => { ws.onclose = r; setTimeout(() => r({ code: 'timeout' }), 8000); });
  ws.close(1000, 'bye'); const ev = await c;
  ok('client close(1000): Node WebSocket sees clean 1000', ev.code === 1000 && ev.wasClean === true, `code=${ev.code} clean=${ev.wasClean}`);
}
{
  const ws = new WebSocket(url); await new Promise((r, j) => { ws.onopen = r; ws.onerror = j; });
  const c = new Promise((r) => { ws.onclose = r; setTimeout(() => r({ code: 'timeout' }), 8000); });
  ws.close(3999, 'app'); const ev = await c;
  ok('client close(3999): Node WebSocket sees clean 3999', ev.code === 3999 && ev.wasClean === true, `code=${ev.code} clean=${ev.wasClean}`);
}
// ---- server-initiated close
{
  const ws = await open(); const c = closed(ws); ws.send('close-me'); const ev = await c;
  ok('server close: `ws` client sees a clean close', ev.code === 1000 || ev.code === 1005, `code=${ev.code}`);
  const ws2 = await open(); const c2 = closed(ws2); ws2.send('close-me:4000'); const ev2 = await c2;
  ok('server close with status 4000 (facil only): `ws` client sees 4000', ev2.code === 4000, `code=${ev2.code}`);
  const w3 = new WebSocket(url); await new Promise((r, j) => { w3.onopen = r; w3.onerror = j; });
  const c3 = new Promise((r) => { w3.onclose = r; setTimeout(() => r({ code: 'timeout' }), 8000); });
  w3.send('close-me'); const ev3 = await c3;
  ok('server close: Node WebSocket sees a clean close', ev3.wasClean === true, `code=${ev3.code} clean=${ev3.wasClean}`);
}
// ---- protocol violations (raw client)
{
  let r = await raw(); r.send(1, Buffer.from([0x68, 0xc3, 0x28, 0x69]));
  let code = await r.closeCode();
  ok('invalid UTF-8 in a text frame closes with 1007', code === 1007, `got ${code}`); r.s.destroy();
  r = await raw(); r.send(1, Buffer.from([0xed, 0xa0, 0x80]));
  code = await r.closeCode();
  ok('UTF-16 surrogate in a text frame closes with 1007', code === 1007, `got ${code}`); r.s.destroy();
  r = await raw(); r.send(1, 'unmasked', { mask: false });
  code = await r.closeCode();
  ok('unmasked client frame closes with 1002', code === 1002, `got ${code}`); r.s.destroy();
  r = await raw(); r.send(1, 'rsv set', { rsv: 4 });
  code = await r.closeCode();
  ok('RSV1 without a negotiated extension closes with 1002', code === 1002, `got ${code}`); r.s.destroy();
  r = await raw(); r.send(3, 'reserved opcode');
  code = await r.closeCode();
  ok('reserved opcode closes with 1002', code === 1002, `got ${code}`); r.s.destroy();
  r = await raw(); r.send(9, Buffer.alloc(126));
  code = await r.closeCode();
  ok('126-byte ping closes with 1002', code === 1002, `got ${code}`); r.s.destroy();
  r = await raw(); r.send(8, Buffer.from([0x03, 0xe8])); code = await r.closeCode();
  ok('raw Close(1000) is echoed with 1000', code === 1000, `got ${code}`); r.s.destroy();
  r = await raw(); r.send(8, Buffer.alloc(0)); code = await r.closeCode();
  ok('raw Close without status is answered by a Close', code === 'no-status' || code === 1000, `got ${code}`); r.s.destroy();
}
// ---- over the size limit
{
  const max = +(process.env.WS_MAX_MSG || 8388608);
  const ws = await open(); const c = closed(ws, 15000);
  ws.send(crypto.randomBytes(max + 1024)); const ev = await c;
  ok(`message over ws_max_msg_size (${max}) closes with 1009`, ev.code === 1009, `code=${ev.code}`);
  const ws2 = await open(); const c2 = closed(ws2, 15000);
  const piece = crypto.randomBytes(1 << 20);
  for (let i = 0; i < (max >> 20) + 2; i++) ws2.send(piece, { fin: false });
  const ev2 = await c2;
  ok('fragmented message growing past the limit closes with 1009', ev2.code === 1009, `code=${ev2.code}`);
}
// ---- 100 clients x N messages, each intact and in order
{
  const per = quick ? 1000 : 10000, clients = 100, win = 200;
  const t0 = Date.now(); let total = 0, bad = 0;
  await Promise.all(Array.from({ length: clients }, async (_, ci) => {
    const ws = await open();
    await new Promise((res, rej) => {
      let sent = 0, got = 0;
      const body = (i) => { const n = 8 + ((i * 131 + ci * 17) % 900); const s = `${ci}:${i}:`; return s + 'p'.repeat(n) + (i % 7 === 0 ? 'é✓' : ''); };
      const pump = () => { while (sent < per && sent - got < win) { const m = body(sent); (sent % 3 === 0) ? ws.send(Buffer.from(m)) : ws.send(m); sent++; } };
      ws.on('message', (data, isBinary) => {
        if (data.toString() !== body(got) || isBinary !== (got % 3 === 0)) bad++;
        got++; total++;
        if (got === per) { ws.close(); res(); } else pump();
      });
      ws.on('error', rej); ws.on('close', () => { if (got < per) rej(new Error(`client ${ci} closed at ${got}`)); });
      pump();
    });
  })).catch((e) => { bad++; console.log('   ' + e.message); });
  ok(`${clients} clients x ${per} echoes intact, in order, type kept`, bad === 0 && total === clients * per, `total=${total} bad=${bad} ${((Date.now() - t0) / 1000).toFixed(1)}s`);
}
await sleep(500);
const st = await stats();
ok('every opened connection was closed', st.opens === st.closes, `opens=${st.opens} closes=${st.closes}`);
// Last, because it takes stock facil.io down.
{
  const r = await raw(); r.send(0, 'orphan continuation');
  const code = await r.closeCode();
  ok('continuation frame without a start closes with 1002', code === 1002, `got ${code}`); r.s.destroy();
  await sleep(300);
  const alive = await stats().then(() => true, () => false);
  ok('server still up after the orphan continuation frame', alive, alive ? '' : 'SERVER CRASHED');
}
console.log(`SUMMARY port ${port}: ${pass} passed, ${fail} failed in ${((Date.now() - t00) / 1000).toFixed(1)}s`);
process.exit(0);
