// usage: node ws_client.mjs <port>
import crypto from 'node:crypto';
const port = process.argv[2];
const url = `ws://127.0.0.1:${port}/ws`;
const open = () => new Promise((res, rej) => { const ws = new WebSocket(url); ws.binaryType = 'arraybuffer'; ws.onopen = () => res(ws); ws.onerror = e => rej(new Error('ws error ' + (e.message || ''))); });
const next = (ws, ms = 5000) => new Promise((res, rej) => { const t = setTimeout(() => rej(new Error('timeout')), ms); ws.addEventListener('message', e => { clearTimeout(t); res(e.data); }, { once: true }); });
const closed = (ws, ms = 5000) => new Promise((res, rej) => { const t = setTimeout(() => rej(new Error('close timeout')), ms); ws.addEventListener('close', e => { clearTimeout(t); res(e); }, { once: true }); });
const stats = async () => (await (await fetch(`http://127.0.0.1:${port}/stats`)).text()).trim();
const ok = (name, cond, extra = '') => console.log(`${cond ? 'PASS' : 'FAIL'} ${name} ${extra}`);

const ws = await open();
ws.send('hello text'); let r = await next(ws);
ok('text echo', r === 'hello text', JSON.stringify(r));
const bin = crypto.randomBytes(1024); ws.send(bin); r = await next(ws);
ok('binary echo', r instanceof ArrayBuffer && Buffer.from(r).equals(bin), `type=${r.constructor.name} bytes=${r.byteLength}`);

// 1000 round trips, pipelined
let got = []; const all = new Promise(res => { const h = e => { got.push(e.data); if (got.length === 1000) { ws.removeEventListener('message', h); res(); } }; ws.addEventListener('message', h); });
const sent = []; for (let i = 0; i < 1000; i++) { const m = `msg-${i}-${crypto.randomBytes(16 + (i % 200)).toString('hex')}`; sent.push(m); ws.send(m); }
let t0 = Date.now(); await Promise.race([all, new Promise((_, rej) => setTimeout(() => rej(new Error('1000 timeout, got ' + got.length)), 20000))]);
ok('1000 messages intact and in order', got.every((m, i) => m === sent[i]), `count=${got.length} ms=${Date.now() - t0}`);

for (const [label, size] of [['200KB binary', 200 * 1024], ['200KB text', 200 * 1024]]) {
  const big = label.includes('text') ? 'x'.repeat(size - 5) + 'héé' /* multibyte tail */ : crypto.randomBytes(size);
  ws.send(big); r = await next(ws, 10000);
  const same = typeof big === 'string' ? r === big : Buffer.from(r).equals(big);
  ok(label + ' echo', same, `bytes=${typeof r === 'string' ? Buffer.byteLength(r) : r.byteLength}`);
}

t0 = Date.now(); ws.send('push-me'); r = await next(ws);
ok('server push from another Julia thread (uuid + fio_defer_io_task)', /^pushed from julia thread/.test(r), `"${r}" after ${Date.now() - t0}ms (task sleeps 50ms)`);

// pub/sub: second client, publish from Julia
const ws2 = await open();
await new Promise(r => setTimeout(r, 200));
const both = Promise.all([next(ws), next(ws2)]); t0 = Date.now();
await fetch(`http://127.0.0.1:${port}/publish?news`);
const [a, b] = await both;
ok('pub/sub: fio_publish reaches both subscribers', a === b && /^news via thread/.test(a), `"${a}" | "${b}" after ${Date.now() - t0}ms`);

console.log('before closes:', await stats());
// client-initiated close
let c = closed(ws2); ws2.close(1000, 'bye'); let ev = await c;
await new Promise(r => setTimeout(r, 300));
console.log(`client close: code=${ev.code} clean=${ev.wasClean};`, await stats());
// server-initiated close
c = closed(ws); ws.send('close-me'); ev = await c;
await new Promise(r => setTimeout(r, 300));
console.log(`server close: code=${ev.code} clean=${ev.wasClean};`, await stats());
// late send to a closed connection must be dropped, not crash
const ws3 = await open(); ws3.send('push-after-close'); await new Promise(r => setTimeout(r, 50)); c = closed(ws3); ws3.close(); await c;
await new Promise(r => setTimeout(r, 1800));
console.log('after late send to closed uuid:', await stats());
process.exit(0);
