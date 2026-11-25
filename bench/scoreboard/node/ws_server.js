// `ws` package opponent (default options), same routes as uws_server.js.
//   node ws_server.js <port> [deflate]
const http = require('http');
const { WebSocketServer } = require('ws');
const { publisher } = require('./common');
const state = { opens: 0, closes: 0, published: 0 };
const subs = new Set();
const server = http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x');
  if (u.pathname === '/start') {
    const q = u.searchParams;
    state.published = 0;
    publisher(+q.get('n'), +q.get('rate'), +q.get('size'), (m) => { for (const ws of subs) ws.send(m); }, state);
    res.end('started\n');
  } else if (u.pathname === '/stats') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(state));
  } else { res.writeHead(404); res.end(); }
});
const wss = new WebSocketServer({ server, perMessageDeflate: process.argv[3] === 'deflate' });
wss.on('connection', (ws, req) => {
  state.opens++;
  if (req.url === '/sub') { subs.add(ws); ws.on('close', () => { subs.delete(ws); state.closes++; }); }
  else {
    ws.on('message', (data, isBinary) => ws.send(data, { binary: isBinary }));
    ws.on('close', () => state.closes++);
  }
  ws.on('error', () => {});
});
server.listen(+process.argv[2], '127.0.0.1', () => console.log(`READY pid=${process.pid}`));
