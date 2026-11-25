// usage: node errors.mjs <port>   (server started with MAXBODY=1)
// Sends exact bytes; counts the responses that come back and how the connection ends.
import net from 'node:net';
const port = +process.argv[2];
let fail = 0;
const send = (label, payload, want, ms = 1500) => new Promise((res) => {
  const s = net.connect(port, '127.0.0.1'); let buf = Buffer.alloc(0), end = 'left open';
  s.on('connect', () => s.write(payload)); s.on('data', (d) => { buf = Buffer.concat([buf, d]); });
  s.on('end', () => { end = 'closed'; }); s.on('error', (e) => { end = 'error ' + e.code; });
  setTimeout(() => { s.destroy(); const t = buf.toString('latin1');
    const statuses = [...t.matchAll(/HTTP\/1\.1 (\d{3})/g)].map((m) => +m[1]);
    const ok = JSON.stringify(statuses) === JSON.stringify(want.statuses) && (!want.end || want.end.includes(end));
    if (!ok) fail++;
    console.log(`${ok ? 'ok  ' : 'FAIL'} ${label}: statuses=${JSON.stringify(statuses)} conn=${end}${ok ? '' : `  (want ${JSON.stringify(want.statuses)} ${want.end || ''})`}`); res(t); }, ms);
});
const hs = (n) => Array.from({ length: n }, (_, i) => `X-H${i}: v\r\n`).join('');
const closed = ['closed', 'error ECONNRESET', 'error EPIPE'];
await send('header line of 9000 bytes', 'GET /info HTTP/1.1\r\nHost: x\r\nX-Big: ' + 'a'.repeat(9000) + '\r\n\r\n', { statuses: [431], end: closed });
await send('header line of 7000 bytes (allowed)', 'GET /info HTTP/1.1\r\nHost: x\r\nX-Big: ' + 'a'.repeat(7000) + '\r\n\r\n', { statuses: [200], end: ['left open'] });
await send('request line of 9000 bytes', 'GET /' + 'a'.repeat(9000) + ' HTTP/1.1\r\nHost: x\r\n\r\n', { statuses: [414], end: closed });
await send('120 headers (allowed)', 'GET /info HTTP/1.1\r\nHost: x\r\n' + hs(119) + '\r\n', { statuses: [200], end: ['left open'] });
await send('130 headers', 'GET /info HTTP/1.1\r\nHost: x\r\n' + hs(129) + '\r\n', { statuses: [431], end: closed });
await send('100 headers totalling 40 KiB', 'GET /info HTTP/1.1\r\nHost: x\r\n' + Array.from({ length: 100 }, (_, i) => `X-H${i}: ${'b'.repeat(400)}\r\n`).join('') + '\r\n', { statuses: [431], end: closed });
await send('body 2 MiB with Content-Length, limit 1 MiB', 'POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 2097152\r\n\r\n' + 'z'.repeat(2097152), { statuses: [413], end: closed });
await send('Content-Length 2 MiB, no body sent', 'POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 2097152\r\n\r\n', { statuses: [413], end: closed });
const ch = '10000\r\n' + 'z'.repeat(65536) + '\r\n';
await send('chunked body 2 MiB, limit 1 MiB', 'POST /upload HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n' + ch.repeat(32) + '0\r\n\r\n', { statuses: [413], end: closed });
await send('body 512 KiB (allowed)', 'POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 524288\r\n\r\n' + 'z'.repeat(524288), { statuses: [200], end: ['left open'] });
const t = await send('HEAD /hello then GET /json on one connection', 'HEAD /hello HTTP/1.1\r\nHost: x\r\n\r\nGET /json HTTP/1.1\r\nHost: x\r\n\r\n', { statuses: [200, 200], end: ['left open'] });
const headBody = t.split('\r\n\r\n')[1] || '';
const headOk = headBody.startsWith('HTTP/1.1 200');
if (!headOk) fail++;
console.log(`${headOk ? 'ok  ' : 'FAIL'} HEAD response carries no body (bytes after first head: ${JSON.stringify(headBody.slice(0, 20))})`);
await send('garbage request line', '\x16\x03\x01\x02\x00\x01\x00\r\n\r\n', { statuses: [400], end: closed });
console.log(`failures: ${fail}`);
process.exit(0);
