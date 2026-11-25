// usage: node idle.mjs <port> <n> <server timeout secs>
// Opens n keep-alive connections, makes one request on each, then idles and records when the server drops them.
import net from 'node:net';
const port = +process.argv[2], n = +process.argv[3], T = +process.argv[4];
const closedAfter = []; let open = 0;
for (let i = 0; i < n; i++) {
  const s = net.connect(port, '127.0.0.1'); let t0 = 0;
  s.on('connect', () => { open++; s.write('GET /json HTTP/1.1\r\nHost: x\r\n\r\n'); });
  s.once('data', () => { t0 = Date.now(); }); s.on('data', () => {});
  s.on('close', () => { if (t0) closedAfter.push((Date.now() - t0) / 1000); });
  s.on('error', () => {});
  if (i % 100 === 99) await new Promise((r) => setTimeout(r, 10));
}
await new Promise((r) => setTimeout(r, (T + 4) * 1000));
closedAfter.sort((a, b) => a - b);
const ok = closedAfter.length === n && closedAfter[0] >= T - 1 && closedAfter[n - 1] <= T + 2.5;
console.log(`${ok ? 'ok  ' : 'FAIL'} idle timeout ${T} s: ${closedAfter.length}/${n} dropped by server, after ${closedAfter[0]?.toFixed(1)}..${closedAfter[closedAfter.length - 1]?.toFixed(1)} s`);
process.exit(0);
