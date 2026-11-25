// node:https opponent for the TLS rows: GET /json, GET /bytes/<n>.
//   node https_server.js <port> <cert.pem> <key.pem>
const https = require('https'), fs = require('fs');
const SMALL_JSON = '{"id":1,"name":"alice","email":"alice@example.com","tags":["admin","reviewer"],"created_at":"2024-01-01T12:00:00Z","status":"active","login_count":42}';
const bufs = new Map();
const xbuf = (n) => { let b = bufs.get(n); if (!b) bufs.set(n, b = Buffer.alloc(n, 'x')); return b; };
const server = https.createServer({ cert: fs.readFileSync(process.argv[3]), key: fs.readFileSync(process.argv[4]) }, (req, res) => {
  const t = req.url;
  if (t === '/json') {
    res.writeHead(200, { 'Content-Type': 'application/json', 'Content-Length': String(SMALL_JSON.length) });
    res.end(SMALL_JSON);
  } else if (t.startsWith('/bytes/')) {
    const b = xbuf(+t.slice(7));
    res.writeHead(200, { 'Content-Type': 'application/octet-stream', 'Content-Length': String(b.length) });
    res.end(b);
  } else {
    res.writeHead(404, { 'Content-Length': '0' });
    res.end();
  }
});
server.keepAliveTimeout = 60000;
server.listen(+process.argv[2], '127.0.0.1', () => console.log(`READY pid=${process.pid} openssl=${process.versions.openssl}`));
