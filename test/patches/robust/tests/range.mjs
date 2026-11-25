// usage: node range.mjs <port> <file under public/> [only=substr]
// Single-range checks per RFC 9110 against a static file; probes liveness after each case.
import net from 'node:net';
import fs from 'node:fs';
import path from 'node:path';
const port = +process.argv[2], name = process.argv[3], only = process.argv[4];
const file = fs.readFileSync(path.join(path.dirname(new URL(import.meta.url).pathname), '..', 'public', name));
const L = file.length;
function req(headers, ms = 3000, method = 'GET', target = '/' + name) {
  return new Promise((res) => {
    const s = net.connect(port, '127.0.0.1'); let buf = Buffer.alloc(0), done = false;
    const fin = (why) => { if (done) return; done = true; s.destroy();
      const i = buf.indexOf('\r\n\r\n'); const head = (i < 0 ? buf : buf.subarray(0, i)).toString('latin1');
      const h = {}; head.split('\r\n').slice(1).forEach((l) => { const k = l.indexOf(':'); h[l.slice(0, k).toLowerCase()] = l.slice(k + 1).trim(); });
      res({ status: +head.split(' ')[1] || 0, h, body: i < 0 ? Buffer.alloc(0) : buf.subarray(i + 4), why }); };
    s.on('connect', () => s.write(`${method} ${target} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n${headers}\r\n`));
    s.on('data', (d) => { buf = Buffer.concat([buf, d]); });
    s.on('end', () => fin('closed')); s.on('error', (e) => fin(e.code)); setTimeout(() => fin('timeout'), ms);
  });
}
const full = { status: 200, a: 0, b: L - 1 };
const part = (a, b) => ({ status: 206, a, b });
const cases = [
  ['no range', '', full],
  ['bytes=0-99', 'Range: bytes=0-99\r\n', part(0, 99)],
  ['bytes=100-199', 'Range: bytes=100-199\r\n', part(100, 199)],
  ['bytes=0-0', 'Range: bytes=0-0\r\n', part(0, 0)],
  ['bytes=100-', 'Range: bytes=100-\r\n', part(100, L - 1)],
  [`bytes=${L - 1}-`, `Range: bytes=${L - 1}-\r\n`, part(L - 1, L - 1)],
  ['bytes=0- (whole file as a range)', 'Range: bytes=0-\r\n', part(0, L - 1)],
  ['bytes=-500 (suffix)', 'Range: bytes=-500\r\n', part(L - 500, L - 1)],
  [`bytes=-${L + 10} (suffix longer than file)`, `Range: bytes=-${L + 10}\r\n`, part(0, L - 1)],
  ['bytes=-0 (unsatisfiable)', 'Range: bytes=-0\r\n', { status: 416 }],
  [`bytes=100-${L + 5000} (end past EOF)`, `Range: bytes=100-${L + 5000}\r\n`, part(100, L - 1)],
  [`bytes=${L}- (start at EOF)`, `Range: bytes=${L}-\r\n`, { status: 416 }],
  [`bytes=${L + 100}-${L + 200}`, `Range: bytes=${L + 100}-${L + 200}\r\n`, { status: 416 }],
  ['bytes=200-100 (invalid, ignored)', 'Range: bytes=200-100\r\n', full],
  ['bytes=abc (invalid, ignored)', 'Range: bytes=abc\r\n', full],
  ['bytes= (empty)', 'Range: bytes=\r\n', full],
  ['by (short value)', 'Range: by\r\n', full],
  ['items=0-5 (unknown unit)', 'Range: items=0-5\r\n', full],
  ['bytes=0-9,20-29 (multi, falls back)', 'Range: bytes=0-9,20-29\r\n', full],
  ['bytes=99999999999999999999-', 'Range: bytes=99999999999999999999-\r\n', { status: 416 }],
  ['bytes=0-99999999999999999999', 'Range: bytes=0-99999999999999999999\r\n', part(0, L - 1)],
  ['bytes=-99999999999999999999', 'Range: bytes=-99999999999999999999\r\n', part(0, L - 1)],
  ['bytes=-9223372036854775808', 'Range: bytes=-9223372036854775808\r\n', part(0, L - 1)],
  ['bytes=0x10-0x20 (hex must not parse)', 'Range: bytes=0x10-0x20\r\n', full],
  ['HEAD bytes=0-99', 'Range: bytes=0-99\r\n', { status: 206, a: 0, b: 99, head: true }],
];
let fail = 0;
for (const [label, hdr, want] of cases) {
  if (only && !label.includes(only)) continue;
  const r = await req(hdr, 3000, want.head ? 'HEAD' : 'GET');
  const problems = [];
  if (r.status !== want.status) problems.push(`status ${r.status} != ${want.status}`);
  if (r.why !== 'closed') problems.push(`conn ${r.why}`);
  if (want.status === 416) {
    if (r.h['content-range'] !== `bytes */${L}`) problems.push(`content-range ${r.h['content-range']}`);
  } else if (r.status === want.status) {
    const n = want.b - want.a + 1;
    if (+r.h['content-length'] !== n) problems.push(`content-length ${r.h['content-length']} != ${n}`);
    if (!want.head && !r.body.equals(file.subarray(want.a, want.b + 1))) problems.push(`body mismatch (${r.body.length} bytes)`);
    if (want.head && r.body.length) problems.push('HEAD has body');
    if (want.status === 206 && r.h['content-range'] !== `bytes ${want.a}-${want.b}/${L}`) problems.push(`content-range ${r.h['content-range']}`);
    if (want.status === 200 && r.h['content-range']) problems.push('200 with content-range');
  }
  const alive = await req('', 2000, 'GET', '/json');
  if (alive.status !== 200) problems.push('SERVER UNRESPONSIVE AFTERWARDS');
  if (problems.length) fail++;
  console.log(`${problems.length ? 'FAIL' : 'ok  '} ${label}${problems.length ? ': ' + problems.join('; ') : ''}`);
  if (alive.status !== 200) break;
}
const r = await req('');
if (r.status === 200) {
  const e = r.h.etag || '';
  console.log(`etag ${e}: ${/^(W\/)?"[^"]*"$/.test(e) ? 'ok   quoted' : 'FAIL unquoted'}`);
  const c = await req(`If-None-Match: ${e}\r\n`); console.log(`${c.status === 304 ? 'ok  ' : 'FAIL'} If-None-Match -> ${c.status}`);
  const d = await req(`If-None-Match: "nope", ${e}\r\n`); console.log(`${d.status === 304 ? 'ok  ' : 'FAIL'} If-None-Match list -> ${d.status}`);
  const f = await req(`If-Range: ${e}\r\nRange: bytes=0-9\r\n`); console.log(`${f.status === 206 ? 'ok  ' : 'FAIL'} If-Range match + Range -> ${f.status}`);
  const g = await req(`If-Range: "stale"\r\nRange: bytes=0-9\r\n`); console.log(`${g.status === 200 ? 'ok  ' : 'FAIL'} If-Range mismatch + Range -> ${g.status}`);
}
console.log(`failures: ${fail}`);
process.exit(0);
