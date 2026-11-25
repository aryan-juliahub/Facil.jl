// usage: node raw_check.mjs <port>   (server started with max_body_size 1 MiB)
// Sends exact bytes and checks the status codes and connection fate.
import net from 'node:net';
const port = +process.argv[2];
const send = (payload, ms = 2500) => new Promise(res => {
  const s = net.connect(port, '127.0.0.1'); let buf = Buffer.alloc(0), closed = false;
  s.on('connect', () => s.write(payload)); s.on('data', d => buf = Buffer.concat([buf, d]));
  s.on('end', () => closed = true); s.on('error', () => closed = true); s.on('close', () => closed = true);
  setTimeout(() => {
    s.destroy(); const t = buf.toString('latin1');
    const statuses = [...t.matchAll(/HTTP\/1\.[01] (\d{3})/g)].map(m => +m[1]);
    res({ statuses, closed, text: t, bytes: buf.length });
  }, ms);
});
const ok = (name, cond, extra = '') => console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}  (${extra})`);
const check = async (name, payload, want, wantClosed) => {
  const r = await send(payload);
  ok(name, JSON.stringify(r.statuses) === JSON.stringify(want) && (wantClosed === undefined || r.closed === wantClosed),
     `statuses=${JSON.stringify(r.statuses)} closed=${r.closed}`);
  return r;
};
let r = await send('HEAD /hello HTTP/1.1\r\nHost: x\r\n\r\nGET /hello HTTP/1.1\r\nHost: x\r\n\r\n');
const firstHead = r.text.split('\r\n\r\n')[0];
ok('features: HEAD via http_send_body sends headers only, next request intact',
   /content-length:\s*13/i.test(firstHead) && r.text.split('\r\n\r\n')[1].startsWith('HTTP/1.1 200') && r.text.endsWith('Hello World!\n'),
   `bytes=${r.bytes}`);
// facil.io requires Host on every request; the 400 keeps an HTTP/1.1 connection open
await check('features: HTTP/1.1 without Host', 'GET /info HTTP/1.1\r\n\r\n', [400], false);
await check('features: HTTP/1.0 without Host', 'GET /info HTTP/1.0\r\n\r\n', [400], true);
await check('features: header line of 9000 bytes', 'GET /info HTTP/1.1\r\nHost: x\r\nX-Big: ' + 'a'.repeat(9000) + '\r\n\r\n', [431], true);
await check('features: header line of 7000 bytes', 'GET /info HTTP/1.1\r\nHost: x\r\nX-Big: ' + 'a'.repeat(7000) + '\r\n\r\n', [200], false);
const hs = n => Array.from({ length: n }, (_, i) => `X-H${i}: v\r\n`).join('');
await check('features: 120 headers', 'GET /info HTTP/1.1\r\nHost: x\r\n' + hs(119) + '\r\n', [200], false);
await check('features: 130 headers', 'GET /info HTTP/1.1\r\nHost: x\r\n' + hs(129) + '\r\n', [431], true);
await check('features: 100 headers totalling 40 KiB', 'GET /info HTTP/1.1\r\nHost: x\r\n' + Array.from({ length: 100 }, (_, i) => `X-H${i}: ${'b'.repeat(400)}\r\n`).join('') + '\r\n', [431], true);
await check('features: 2 MiB body over a 1 MiB limit', 'POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 2097152\r\n\r\n' + 'z'.repeat(2097152), [413], true);
await check('features: Content-Length 2 MiB, no body sent', 'POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 2097152\r\n\r\n', [413]);
const ch = '10000\r\n' + 'z'.repeat(65536) + '\r\n';
await check('features: chunked 2 MiB over a 1 MiB limit', 'POST /upload HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n' + ch.repeat(32) + '0\r\n\r\n', [413], true);
r = await check('features: 512 KiB body under the limit', 'POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 524288\r\n\r\n' + 'z'.repeat(524288), [200], false);
process.exit(0);
