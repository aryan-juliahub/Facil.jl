// usage: node flood.mjs <port> <clients>
// Clients ask for a response written in 1,500 pieces of 64 KiB and never read it.
import net from 'node:net';
const port = +process.argv[2], n = +process.argv[3];
const socks = [];
for (let i = 0; i < n; i++) { const s = net.connect(port, '127.0.0.1'); s.pause(); s.on('error', () => {}); s.on('connect', () => s.write('GET /flood HTTP/1.1\r\nHost: x\r\n\r\n')); socks.push(s); }
await new Promise((r) => setTimeout(r, +(process.argv[4] || 3) * 1000));
socks.forEach((s) => s.destroy());
await new Promise((r) => setTimeout(r, 1500));
process.exit(0);
