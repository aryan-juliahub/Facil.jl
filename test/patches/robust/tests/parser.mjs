// usage: node parser.mjs <port> <case>    cases: negchunk | stale-lf | cl-neg | cl-te | cl-huge | chunk-huge
// Each case sends hostile framing, then probes whether the server still answers.
import net from 'node:net';
const port = +process.argv[2], which = process.argv[3];
const talk = (steps, ms = 1500) => new Promise((res) => {
  const s = net.connect(port, '127.0.0.1'); let buf = '', end = 'left open';
  s.on('data', (d) => { buf += d.toString('latin1'); }); s.on('end', () => { end = 'closed'; }); s.on('error', (e) => { end = 'error ' + e.code; });
  s.on('connect', async () => { for (const st of steps) { if (typeof st === 'number') await new Promise((r) => setTimeout(r, st)); else s.write(st); } });
  setTimeout(() => { s.destroy(); res({ statuses: [...buf.matchAll(/HTTP\/1\.1 (\d{3})/g)].map((m) => +m[1]), end, buf }); }, ms);
});
const alive = async () => (await talk(['GET /json HTTP/1.1\r\nHost: x\r\n\r\n'], 1500)).statuses[0] === 200;
const A = 'GET /json HTTP/1.1\r\nHost: x\r\n\r\n';
const cases = {
  // chunk size -5 written in 5 bytes: the parser steps back onto the same chunk line forever
  negchunk: () => talk(['POST /upload HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n-05\r\nhello\r\n0\r\n\r\n']),
  // a full request, then the same request minus its last LF: the parser reads the stale LF past the data
  'stale-lf': () => talk([A, 300, A.slice(0, -1), 300, 'GET /json HTTP/1.1\r\nHost: x\r\n\r\n'], 2000),
  'cl-neg': () => talk(['POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: -5\r\n\r\nhello']),
  'cl-te': () => talk(['POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\nGET /smuggled HTTP/1.1\r\nHost: x\r\n\r\n']),
  'cl-huge': () => talk(['POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 99999999999999999999999\r\n\r\nhello']),
  'chunk-huge': () => talk(['POST /upload HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n7FFFFFFFFFFFFFFF\r\nhello\r\n0\r\n\r\n']),
};
const r = await cases[which]();
console.log(`${which}: statuses=${JSON.stringify(r.statuses)} conn=${r.end} | server alive afterwards: ${await alive()}`);
if (which === 'cl-te') console.log('   bodies: ' + JSON.stringify(r.buf.split('\r\n\r\n').filter((x) => !x.startsWith('HTTP')).join('|').slice(0, 200)));
process.exit(0);
