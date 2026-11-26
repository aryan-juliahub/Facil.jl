// TLS clients that finish sending at once. Usage: node halfclose.js <port> <mode> <n> <path>
// mode end: write the request and end (close_notify + FIN), read the reply to its end.
// mode destroy: write the request and drop the socket as soon as it is written.
// Prints "<complete replies> <bytes>" (end) or "<sockets written>" (destroy).
const tls = require('tls');
const [port, mode, n, path] = [Number(process.argv[2]), process.argv[3], Number(process.argv[4]), process.argv[5]];
const request = `GET ${path} HTTP/1.1\r\nHost: x\r\n\r\n`;

function one() {
  return new Promise((resolve) => {
    const chunks = [];
    const s = tls.connect({ host: '127.0.0.1', port, rejectUnauthorized: false }, () => {
      if (mode === 'end') s.end(request);
      else s.write(request, () => { s.destroy(); resolve(1); });
    });
    s.on('data', (c) => chunks.push(c));
    s.on('error', () => resolve(0));
    s.on('close', () => {
      const got = Buffer.concat(chunks);
      const head = got.indexOf('\r\n\r\n');
      const m = /content-length: ?(\d+)/i.exec(got.subarray(0, Math.max(head, 0)).toString());
      resolve(head > 0 && m && got.length - head - 4 === Number(m[1]) ? got.length - head - 4 : 0);
    });
  });
}

(async () => {
  let ok = 0, bytes = 0;
  for (let i = 0; i < n; i++) {
    const r = await one();
    if (mode === 'end') { ok += r > 0 ? 1 : 0; bytes += r; } else ok += r;
  }
  console.log(mode === 'end' ? `${ok} ${bytes}` : `${ok}`);
})();
