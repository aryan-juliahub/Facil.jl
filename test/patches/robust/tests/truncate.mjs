// usage: node truncate.mjs <port>    A static file shrinks while a slow client is downloading it.
import net from 'node:net';
import fs from 'node:fs';
import path from 'node:path';
const port = +process.argv[2];
const f = path.join(path.dirname(new URL(import.meta.url).pathname), '..', 'public', 'shrink.bin');
fs.writeFileSync(f, Buffer.alloc(30 << 20, 'q'));
const s = net.connect(port, '127.0.0.1'); let got = 0, end = 'open';
s.on('connect', () => { s.write('GET /shrink.bin HTTP/1.1\r\nHost: x\r\n\r\n'); s.pause(); });
s.on('data', (d) => { got += d.length; }); s.on('end', () => { end = 'closed'; }); s.on('error', (e) => { end = e.code; });
await new Promise((r) => setTimeout(r, 500));
fs.truncateSync(f, 1 << 20);
s.resume();
await new Promise((r) => setTimeout(r, 2500));
const alive = await new Promise((r) => { const c = net.connect(port, '127.0.0.1'); let b = ''; c.on('connect', () => c.write('GET /json HTTP/1.1\r\nHost: x\r\n\r\n')); c.on('data', (d) => { b += d; }); c.on('error', () => {}); setTimeout(() => { c.destroy(); r(b.startsWith('HTTP/1.1 200')); }, 1500); });
console.log(`${alive && end !== 'open' ? 'ok  ' : 'FAIL'} file truncated mid-download: client got ${got} bytes, conn=${end}, server alive afterwards: ${alive}`);
s.destroy(); fs.unlinkSync(f);
process.exit(0);
