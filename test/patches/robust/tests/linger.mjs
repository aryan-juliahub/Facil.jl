// usage: node linger.mjs <port>   (server with MAXBODY=1)  A rejected client that will not go away must still be dropped.
import net from 'node:net';
const port = +process.argv[2];
const run = (label, drip, limit) => new Promise((res) => {
  const s = net.connect({ port, host: '127.0.0.1', allowHalfOpen: true }); const t0 = Date.now(); let status = '', gone = 0;
  s.on('connect', () => s.write('POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 2097152\r\n\r\n'));
  s.on('data', (d) => { status = status || d.toString('latin1', 9, 12); });
  // a silent client only learns that the server is gone by writing, so it probes once at the limit
  const tm = drip ? setInterval(() => { if (!gone) s.write('z'.repeat(1024)); }, 100) : null;
  if (!drip) setTimeout(() => { if (!gone) { s.write('z'); setTimeout(() => { if (!gone) s.write('z'); }, 200); } }, limit * 1000);
  const done = (why) => { if (gone) return; gone = (Date.now() - t0) / 1000; clearInterval(tm); const ok = status === '413' && gone <= limit + 1;
    console.log(`${ok ? 'ok  ' : 'FAIL'} ${label}: got ${status}, server dropped the connection after ${gone.toFixed(1)} s (${why}), limit ${limit} s`); s.destroy(); res(); };
  s.on('error', (e) => done(e.code)); s.on('close', () => done('close'));
  setTimeout(() => { if (!gone) { gone = -1; clearInterval(tm); console.log(`FAIL ${label}: got ${status}, still connected after ${limit + 3} s`); s.destroy(); res(); } }, (limit + 3) * 1000);
});
await Promise.all([run('rejected client keeps uploading', true, 13), run('rejected client goes silent but stays connected', false, 6)]);
process.exit(0);
