// uWebSockets.js opponent: /echo, /sub (channel "room"), GET /start?n=&rate=&size=, GET /stats.
//   node uws_server.js <port> [deflate]
const uWS = require('uWebSockets.js');
const { publisher } = require('./common');
const state = { opens: 0, closes: 0, published: 0 };
const DEFLATE = process.argv[3] === 'deflate';
const opts = { maxPayloadLength: 1 << 20, maxBackpressure: 1 << 30, closeOnBackpressureLimit: false, idleTimeout: 120,
  compression: DEFLATE ? uWS.SHARED_COMPRESSOR : uWS.DISABLED };
const app = uWS.App();
app.ws('/echo', { ...opts,
  open: () => { state.opens++; }, close: () => { state.closes++; },
  message: (ws, msg, isBinary) => { ws.send(msg, isBinary, DEFLATE); } });
app.ws('/sub', { ...opts,
  open: (ws) => { state.opens++; ws.subscribe('room'); }, close: () => { state.closes++; } });
app.get('/start', (res, req) => {
  const q = new URLSearchParams(req.getQuery());
  state.published = 0;
  publisher(+q.get('n'), +q.get('rate'), +q.get('size'), (m) => app.publish('room', m, false), state);
  res.end('started\n');
});
app.get('/stats', (res) => { res.writeHeader('Content-Type', 'application/json').end(JSON.stringify(state)); });
app.listen('127.0.0.1', +process.argv[2], (tok) => { if (!tok) { console.error('listen failed'); process.exit(1); } console.log(`READY pid=${process.pid}`); });
