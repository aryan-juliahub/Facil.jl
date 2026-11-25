// Usage: node verify.js <port> <pattern|pipeline|head|load|disconnect> [args]
const net = require('net');
const crypto = require('crypto');
const port = +process.argv[2], cmd = process.argv[3], args = process.argv.slice(4);

function pattern(n) { const b = Buffer.alloc(n); for (let i = 0; i < n; i++) b[i] = (i * 7 + (i >>> 10)) & 255; return b; }
const sha = (b) => crypto.createHash('sha256').update(b).digest('hex');

// Content-length based response reader over one socket. HEAD answers carry no body.
function reader(sock, onResponse) {
  let buf = Buffer.alloc(0), head = null, expectHead = [];
  sock.on('data', (d) => {
    buf = buf.length ? Buffer.concat([buf, d]) : d;
    for (;;) {
      if (!head) {
        const i = buf.indexOf('\r\n\r\n');
        if (i < 0) return;
        const text = buf.subarray(0, i).toString('latin1');
        const m = /content-length:\s*(\d+)/i.exec(text);
        head = { text, status: +text.split(' ')[1], len: m ? +m[1] : 0, nobody: expectHead.shift() === true };
        buf = buf.subarray(i + 4);
      }
      const need = head.nobody ? 0 : head.len;
      if (buf.length < need) return;
      const body = buf.subarray(0, need);
      buf = buf.subarray(need);
      const h = head; head = null;
      onResponse(h, body);
    }
  });
  return { expect: (isHead) => expectHead.push(isHead), pending: () => buf.length };
}
const req = (m, p, extra = '') => `${m} ${p} HTTP/1.1\r\nhost: 127.0.0.1:${port}\r\n${extra}\r\n`;

if (cmd === 'pattern') {
  process.stdout.write(pattern(+args[0]));
} else if (cmd === 'pipeline') {
  // Several requests written in one go; answers must come back complete and in order.
  const sizes = args.length ? args.map(Number) : [32768, 1000, 102400, 1, 1048576, 8192];
  const sock = net.connect(port, '127.0.0.1');
  let k = 0, bad = 0;
  const r = reader(sock, (h, body) => {
    const ok = h.status === 200 && body.length === sizes[k] && sha(body) === sha(pattern(sizes[k]));
    if (!ok) bad++;
    console.log(`pipelined #${k + 1} /s/${sizes[k]} status=${h.status} len=${body.length} ${ok ? 'OK' : 'BAD'}`);
    if (++k === sizes.length) { console.log(`pipeline: ${sizes.length - bad}/${sizes.length} correct, in order, one connection`); sock.destroy(); process.exit(bad ? 1 : 0); }
  });
  sizes.forEach(() => r.expect(false));
  sock.write(sizes.map((n) => req('GET', '/s/' + n)).join(''));
  setTimeout(() => { console.log(`pipeline: TIMEOUT after ${k} responses`); process.exit(1); }, 10000);
} else if (cmd === 'head') {
  // HEAD then GET on one connection: if HEAD carried a body the GET answer is misparsed.
  const n = +(args[0] || 102400);
  const sock = net.connect(port, '127.0.0.1');
  let k = 0, res = [];
  const r = reader(sock, (h, body) => {
    res.push({ status: h.status, cl: h.len, body: body.length, sha: sha(body) });
    if (++k === 2) setTimeout(() => {
      const extra = r.pending();
      const ok = res[0].status === 200 && res[0].cl === n && res[1].status === 200 && res[1].body === n && res[1].sha === sha(pattern(n)) && extra === 0;
      console.log(`HEAD /s/${n}: status=${res[0].status} content-length=${res[0].cl}; following GET status=${res[1].status} len=${res[1].body} bodyok=${res[1].sha === sha(pattern(n))} stray_bytes=${extra} => ${ok ? 'OK' : 'BAD'}`);
      process.exit(ok ? 0 : 1);
    }, 300);
  });
  r.expect(true); r.expect(false);
  sock.write(req('HEAD', '/s/' + n) + req('GET', '/s/' + n));
  setTimeout(() => { console.log(`head: TIMEOUT after ${k} responses (HEAD answer carried a body?) first=${JSON.stringify(res[0])}`); process.exit(1); }, 5000);
} else if (cmd === 'load') {
  // Keep-alive connections fetching fresh bodies; every byte of every body is checked.
  const secs = +(args[0] || 30), conns = +(args[1] || 32), sizes = (args[2] || '1024,32768,102400,1048576').split(',').map(Number);
  const kind = args[3] || 'fresh';
  let ok = 0, corrupt = 0, bytes = 0, errors = 0, done = false, open = 0, firstBad = null;
  const seen = new Set(); let dup = 0;
  const end = Date.now() + secs * 1000;
  function check(body, n) {
    if (body.length !== n) return 'length ' + body.length;
    if (kind === 'freshstr') { const c = body[0]; for (let i = 1; i < n; i++) if (body[i] !== c) return `byte ${i}`; return null; }
    let seq = 0;
    for (let k = Math.min(7, n - 1); k >= 0; k--) seq = seq * 256 + body[k];
    if (n >= 8) { if (seen.has(seq)) dup++; else seen.add(seq); }
    const fillb = n >= 8 ? seq & 255 : null;
    for (let i = 8; i < n; i++) if (body[i] !== fillb) return `seq ${seq} byte ${i} is ${body[i]} want ${fillb}`;
    return null;
  }
  for (let c = 0; c < conns; c++) {
    const sock = net.connect(port, '127.0.0.1'); open++;
    let n = 0;
    const r = reader(sock, (h, body) => {
      const why = h.status !== 200 ? 'status ' + h.status : check(body, n);
      if (why) { corrupt++; firstBad = firstBad || why; } else ok++;
      bytes += body.length;
      if (Date.now() < end) send(); else sock.end();
    });
    const send = () => { n = sizes[(Math.random() * sizes.length) | 0]; r.expect(false); sock.write(req('GET', `/${kind}/${n}`)); };
    sock.on('connect', send);
    sock.on('error', () => { errors++; });
    sock.on('close', () => { if (--open === 0 && !done) { done = true; console.log(`load ${secs}s x${conns} conns sizes=${sizes}: responses=${ok + corrupt} ok=${ok} corrupt=${corrupt} dup_seq=${dup} socket_errors=${errors} MB=${(bytes / 1048576) | 0}${firstBad ? ' first_bad=' + firstBad : ''}`); process.exit(corrupt || errors ? 1 : 0); } });
  }
} else if (cmd === 'disconnect') {
  // Start a big download, read a little, drop the connection.
  const times = +(args[0] || 1000), n = +(args[1] || 10485760), par = 20;
  let started = 0, finished = 0, gotBytes = 0;
  function one() {
    if (started >= times) return;
    started++;
    const sock = net.connect(port, '127.0.0.1');
    let got = 0, closed = false;
    const fin = () => { if (closed) return; closed = true; gotBytes += got; finished++; if (finished === times) { console.log(`disconnect: ${times} aborted downloads of ${n} bytes, avg bytes read before abort=${(gotBytes / times) | 0}`); process.exit(0); } one(); };
    sock.on('connect', () => sock.write(req('GET', '/fresh/' + n)));
    sock.on('data', (d) => { got += d.length; if (got >= 65536) sock.destroy(); });
    sock.on('error', () => {});
    sock.on('close', fin);
  }
  for (let i = 0; i < par; i++) one();
}
