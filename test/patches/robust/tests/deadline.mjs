// usage: node deadline.mjs <port> <hdr_timeout_secs>
// Legitimate slow traffic that a header deadline must not break.
import net from 'node:net';
const port = +process.argv[2], T = +process.argv[3];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
function conn() {
  const s = net.connect(port, '127.0.0.1'); const c = { s, buf: '', end: 'open' };
  s.on('data', (d) => { c.buf += d.toString('latin1'); }); s.on('end', () => { c.end = 'closed'; }); s.on('error', (e) => { c.end = 'error ' + e.code; });
  return new Promise((r) => s.on('connect', () => r(c)));
}
const statuses = (c) => [...c.buf.matchAll(/HTTP\/1\.1 (\d{3})/g)].map((m) => +m[1]);
let fail = 0;
const check = (label, c, want, wantEnd) => { const got = statuses(c); const ok = JSON.stringify(got) === JSON.stringify(want) && c.end === wantEnd; if (!ok) fail++;
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${label}: statuses=${JSON.stringify(got)} conn=${c.end}`); c.s.destroy(); };

const t0 = Date.now();
// 1. body uploaded slowly for 2.5x the header deadline
const up = (async () => { const c = await conn(); const n = 50; c.s.write(`POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: ${n * 100}\r\n\r\n`);
  for (let i = 0; i < n; i++) { c.s.write('u'.repeat(100)); await sleep(T * 2500 / n); } await sleep(500); check(`slow body upload over ${(T * 2.5).toFixed(1)} s`, c, [200], 'open'); })();
// 2. chunked body uploaded slowly
const ch = (async () => { const c = await conn(); c.s.write('POST /upload HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n');
  for (let i = 0; i < 25; i++) { c.s.write('64\r\n' + 'c'.repeat(100) + '\r\n'); await sleep(T * 2500 / 25); } c.s.write('0\r\n\r\n'); await sleep(500); check('slow chunked upload', c, [200], 'open'); })();
// 3. keep-alive connection idle for 2x the deadline between requests
const ka = (async () => { const c = await conn(); c.s.write('GET /json HTTP/1.1\r\nHost: x\r\n\r\n'); await sleep(T * 2000);
  c.s.write('GET /json HTTP/1.1\r\nHost: x\r\n\r\n'); await sleep(500); check(`keep-alive idle ${T * 2} s then a request`, c, [200, 200], 'open'); })();
// 4. connection that sends nothing at all for 2x the deadline, then a request
const quiet = (async () => { const c = await conn(); await sleep(T * 2000); c.s.write('GET /json HTTP/1.1\r\nHost: x\r\n\r\n'); await sleep(500); check(`silent ${T * 2} s then a request`, c, [200], 'open'); })();
// 5. head split in two writes, well inside the deadline
const split = (async () => { const c = await conn(); c.s.write('GET /json HTTP/1.1\r\nHo'); await sleep(Math.min(1000, T * 400)); c.s.write('st: x\r\n\r\n'); await sleep(500); check('head split across two packets', c, [200], 'open'); })();
// 6. blank line after a request, idle past the deadline, then a split head
const blank = (async () => { const c = await conn(); c.s.write('GET /json HTTP/1.1\r\nHost: x\r\n\r\n'); await sleep(200); c.s.write('\r\n'); await sleep(T * 1500);
  c.s.write('GET /json HTTP/1.1\r\nHo'); await sleep(300); c.s.write('st: x\r\n\r\n'); await sleep(500); check('stray blank line, idle, then a split head', c, [200, 200], 'open'); })();
// 7. the attack shapes: a head that never ends, and blank lines forever
const drip = (async () => { const c = await conn(); const head = 'GET /json HTTP/1.1\r\nHost: x\r\n' + 'X-Pad: aaaaaaaa\r\n'.repeat(400); let i = 0, closedAt = 0;
  c.s.on('close', () => { closedAt = closedAt || Date.now(); });
  const tm = setInterval(() => { if (!c.s.destroyed && c.end === 'open') c.s.write(head[i++]); }, 10); await sleep(T * 1000 + 2500); clearInterval(tm);
  const ok = statuses(c)[0] === 408 && c.end !== 'open'; if (!ok) fail++;
  console.log(`${ok ? 'ok  ' : 'FAIL'} never-ending head: statuses=${JSON.stringify(statuses(c))} conn=${c.end}`); c.s.destroy(); })();
const crlf = (async () => { const c = await conn(); const tm = setInterval(() => { if (!c.s.destroyed && c.end === 'open') c.s.write('\r\n'); }, 10); await sleep(T * 1000 + 2500); clearInterval(tm);
  const ok = c.end !== 'open'; if (!ok) fail++;
  console.log(`${ok ? 'ok  ' : 'FAIL'} blank lines forever: statuses=${JSON.stringify(statuses(c))} conn=${c.end}`); c.s.destroy(); })();
await Promise.all([up, ch, ka, quiet, split, blank, drip, crlf]);
console.log(`failures: ${fail}  (${((Date.now() - t0) / 1000).toFixed(1)} s)`);
process.exit(0);
