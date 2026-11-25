// Body-verifying client for the v9 write-path spike.
// usage: node verify.js <port> <command> [args]     (TLS=1 for https)
//   shapes    <kinds,..>                 every benchmark shape once per kind, patterned, every byte checked
//   keepalive <kind> [count=5]           streamed responses one after another on one connection
//   pipeline  <kind> [times=3]           3 streams + small responses written in one burst, repeated
//   whole     <modes,..>                 whole responses 1..1 MB, patterned, sequential + pipelined
//   load      <secs> <conns> <kinds,..>  mixed streams and whole responses with fresh buffers
//   disconnect <kind> <times>            drop the connection after 64 KB of a long stream
//   slow      <kind> <chunks> <bytes> <kbps> <secs>   read slowly, then at full speed; verify all of it
const net = require('net'), tls = require('tls');
const port = +process.argv[2], cmd = process.argv[3], args = process.argv.slice(4);
const TLS = process.env.TLS === '1';
const HOST = process.env.BHOST || '::1';
const connect = () => TLS ? tls.connect({ port, host: HOST, rejectUnauthorized: false }) : net.connect(port, HOST);
const req = (p) => `GET ${p} HTTP/1.1\r\nhost: x\r\n\r\n`;

const FILL = new Map();
const fillBuf = (b) => { let f = FILL.get(b); if (!f) FILL.set(b, f = Buffer.alloc(65536, b)); return f; };
function allEqual(piece, b) {
  const f = fillBuf(b);
  for (let o = 0; o < piece.length; o += 65536) {
    const n = Math.min(65536, piece.length - o);
    if (piece.compare(f, 0, n, o, o + n) !== 0) return false;
  }
  return true;
}
const seen = new Set(); let dupSeq = 0;

// ---- expectations: each gets the response's bytes as they arrive
function pStream(kind, n, bytes) {     // /p/: fresh self-describing chunks
  let k = -1, pos = 0, hdr = Buffer.alloc(12), seq = -1, fill = 0, err = null, total = 0;
  return {
    path: `/p/${kind}/${n}/${bytes}`, chunked: true,
    chunkStart(len) { k++; pos = 0; if (len !== bytes && !err) err = `chunk ${k} length ${len} want ${bytes}`; },
    data(piece) {
      total += piece.length;
      let o = 0;
      while (pos < 12 && o < piece.length) hdr[pos++] = piece[o++];
      if (pos === 12 && o <= piece.length && this._hdrFor !== k) {
        this._hdrFor = k;
        const s = Number(hdr.readBigUInt64LE(0)), idx = hdr.readUInt32LE(8);
        if (k === 0) { seq = s; if (seen.has(s)) dupSeq++; else seen.add(s); }
        else if (s !== seq && !err) err = `chunk ${k} belongs to response ${s}, not ${seq}`;
        if (idx !== k && !err) err = `chunk index ${idx} at position ${k}`;
        fill = (s * 31 + idx) & 255;
      }
      if (o < piece.length) {
        if (!allEqual(piece.subarray(o), fill) && !err) err = `foreign byte in chunk ${k} of response ${seq}`;
        pos += piece.length - o;
      }
    },
    finish() { return err || (k + 1 !== n ? `${k + 1} chunks, want ${n}` : total !== n * bytes ? `bytes ${total}` : null); },
  };
}
function xStream(kind, n, kb) {         // /s/: 'x' filled
  let total = 0, err = null;
  return {
    path: `/s/${kind}/${n}/${kb}`, chunked: true, chunkStart() {},
    data(p) { total += p.length; if (!allEqual(p, 120) && !err) err = 'foreign byte'; },
    finish() { return err || (total !== n * kb * 1024 ? `bytes ${total}` : null); },
  };
}
function wPattern(mode, n) {            // /wp/: byte i = (i*7 + (i>>>10)) & 255
  let i = 0, err = null;
  return {
    path: `/wp/${mode}/${n}`, chunked: false,
    data(p) { for (let j = 0; j < p.length; j++, i++) if (p[j] !== ((i * 7 + (i >>> 10)) & 255)) { err = err || `byte ${i}`; i += p.length - j; break; } },
    finish() { return err || (i !== n ? `bytes ${i} want ${n}` : null); },
  };
}
function wFresh(mode, n) {              // /wf/: 8 bytes of sequence number, then its low byte
  let pos = 0, hdr = Buffer.alloc(8), fill = -1, err = null;
  return {
    path: `/wf/${mode}/${n}`, chunked: false,
    data(p) {
      let o = 0;
      while (pos < 8 && o < p.length) hdr[pos++] = p[o++];
      if (pos === 8 && fill < 0) { const s = Number(hdr.readBigUInt64LE(0)); fill = s & 255; if (seen.has(s)) dupSeq++; else seen.add(s); }
      if (o < p.length) { if (!allEqual(p.subarray(o), fill) && !err) err = `foreign byte after ${pos}`; pos += p.length - o; }
    },
    finish() { return err || (pos !== n ? `bytes ${pos} want ${n}` : null); },
  };
}
function text(path, body) {
  const parts = [];
  return { path, chunked: false, data(p) { parts.push(Buffer.from(p)); }, finish() { const b = Buffer.concat(parts).toString(); return b === body ? null : `body ${JSON.stringify(b.slice(0, 40))}`; } };
}

// ---- one connection; responses are matched to expectations in order
function conn(onDone, onClose) {
  const sock = connect();
  const q = [];
  let st = 0, exp = null, head = null, left = 0, acc = Buffer.alloc(0), bytes = 0;
  let sockErr = null;
  const fail = (m) => { st = 9; onDone(exp, m); sock.destroy(); };
  const done = () => {
    let e = exp.finish();
    if (!e && head.status !== 200) e = `status ${head.status}`;
    if (!e && exp.wantClose !== true && /connection:\s*close/i.test(head.text)) e = 'connection: close';
    const x = exp; exp = null; st = 0; onDone(x, e);
  };
  sock.on('data', (d) => {
    bytes += d.length;
    let o = 0;
    while (o < d.length && st !== 9) {
      if (st === 0 || st === 2 || st === 4) {           // line-oriented states: head, chunk size, CRLF after chunk
        acc = acc.length ? Buffer.concat([acc, d.subarray(o)]) : d.subarray(o);
        o = d.length;
        for (;;) {
          if (st === 0) {
            const i = acc.indexOf('\r\n\r\n'); if (i < 0) break;
            if (!q.length) return fail('unexpected response');
            exp = q.shift();
            const t = acc.subarray(0, i).toString('latin1');
            head = { text: t, status: +t.split(' ')[1] };
            acc = acc.subarray(i + 4);
            const ch = /transfer-encoding:\s*chunked/i.test(t), m = /content-length:\s*(\d+)/i.exec(t);
            if (ch !== exp.chunked) return fail(ch ? 'chunked, expected a length' : 'not chunked');
            if (ch) st = 2; else { left = m ? +m[1] : 0; st = 1; if (!left) { done(); continue; } }
          } else if (st === 2) {
            const i = acc.indexOf('\r\n'); if (i < 0) break;
            const line = acc.subarray(0, i).toString('latin1');
            if (!/^[0-9a-f]+$/i.test(line)) return fail('bad chunk size line ' + JSON.stringify(line.slice(0, 30)));
            left = parseInt(line, 16); acc = acc.subarray(i + 2);
            if (left === 0) { st = 4; exp._last = true; } else { exp.chunkStart(left); st = 3; }
          } else if (st === 4) {
            if (acc.length < 2) break;
            if (acc[0] !== 13 || acc[1] !== 10) return fail('chunk not followed by CRLF');
            acc = acc.subarray(2);
            if (exp._last) { done(); } else st = 2;
          }
          if (st === 1 || st === 3) {
            const n = Math.min(left, acc.length);
            if (n) { exp.data(acc.subarray(0, n)); left -= n; acc = acc.subarray(n); }
            if (left === 0) { if (st === 1) done(); else st = 4; } else break;
          }
          if (st === 9) return;
        }
        if (st === 1 || st === 3) acc = Buffer.alloc(0);
      } else {                                           // body bytes
        const n = Math.min(left, d.length - o);
        exp.data(d.subarray(o, o + n)); left -= n; o += n;
        if (left === 0) { if (st === 1) done(); else st = 4; }
      }
    }
  });
  sock.on('error', (e) => { sockErr = e.code || String(e); });
  sock.on('close', () => onClose && onClose(exp || q[0], sockErr));
  return { sock, send(e) { q.push(e); sock.write(req(e.path)); }, sendAll(es) { for (const e of es) q.push(e); sock.write(es.map((e) => req(e.path)).join('')); }, bytes: () => bytes };
}

// run a plan on one connection, sequentially or pipelined
function runPlan(plan, pipelined) {
  return new Promise((resolve) => {
    let i = 0, bad = [];
    const timer = setTimeout(() => { bad.push(`timeout after ${i}/${plan.length}`); c.sock.destroy(); resolve(bad); }, 60000);
    const c = conn((e, err) => {
      if (err) bad.push(`#${i} ${e ? e.path : '?'}: ${err}`);
      i++;
      if (i === plan.length || err) { clearTimeout(timer); c.sock.destroy(); resolve(bad); }
      else if (!pipelined) c.send(plan[i]);
    }, (e, se) => { if (i < plan.length) { clearTimeout(timer); bad.push(`closed after ${i}/${plan.length}${se ? ' (' + se + ')' : ''}`); resolve(bad); } });
    c.sock.on(TLS ? 'secureConnect' : 'connect', () => pipelined ? c.sendAll(plan) : c.send(plan[0]));
  });
}
const SHAPES = [[10, 1024], [100, 16384], [1000, 1024], [10, 1048576]];

(async () => {
  if (cmd === 'shapes') {
    let fails = 0;
    for (const kind of args[0].split(',')) {
      const bad = await runPlan(SHAPES.map(([n, b]) => pStream(kind, n, b)), false);
      const badx = await runPlan(SHAPES.map(([n, b]) => xStream(kind, n, b / 1024)), false);
      const all = bad.concat(badx); fails += all.length;
      console.log(`shapes ${kind}: ${all.length ? 'FAIL ' + all[0] : 'OK 4 patterned + 4 x-filled streams (10x1K 100x16K 1000x1K 10x1M), every byte checked'}`);
    }
    process.exit(fails ? 1 : 0);
  } else if (cmd === 'keepalive') {
    const kind = args[0], count = +(args[1] || 5);
    const plan = []; for (let i = 0; i < count; i++) plan.push(pStream(kind, SHAPES[i % 3][0], SHAPES[i % 3][1]));
    plan.push(text('/ping', 'ok'));
    const bad = await runPlan(plan, false);
    console.log(`keepalive ${kind}: ${bad.length ? 'FAIL ' + bad[0] : `OK ${count} streamed responses + /ping on one connection, none said close`}`);
    process.exit(bad.length ? 1 : 0);
  } else if (cmd === 'pipeline') {
    const kind = args[0], times = +(args[1] || 3);
    const one = () => [pStream(kind, 10, 1024), text('/ping', 'ok'), pStream(kind, 100, 16384), text('/hdr/5', 'ok'), pStream(kind, 1000, 1024), wPattern('gather', 102400), text('/ping', 'ok')];
    let plan = []; for (let i = 0; i < times; i++) plan = plan.concat(one());
    const bad = await runPlan(plan, true);
    console.log(`pipeline x${times} ${kind}: ${bad.length ? 'FAIL ' + bad[0] : `OK ${plan.length} responses in order from one burst (${times * 3} streams)`}`);
    process.exit(bad.length ? 1 : 0);
  } else if (cmd === 'whole') {
    let fails = 0;
    for (const mode of args[0].split(',')) {
      const sizes = [1, 1024, 8192, 32768, 102400, 1048576, 10485760];
      const bad = (await runPlan(sizes.map((n) => wPattern(mode, n)), false)).concat(await runPlan([32768, 1000, 102400, 1, 1048576, 8192].map((n) => wPattern(mode, n)), true));
      fails += bad.length;
      console.log(`whole ${mode}: ${bad.length ? 'FAIL ' + bad[0] : 'OK 7 sizes keep-alive + 6 pipelined, every byte checked'}`);
    }
    process.exit(fails ? 1 : 0);
  } else if (cmd === 'load') {
    const secs = +args[0], conns = +args[1], kinds = args[2].split(',');
    const end = Date.now() + secs * 1000;
    let ok = 0, bad = 0, first = null, open = 0, bytes = 0, early = 0;
    const next = () => {
      const kind = kinds[(Math.random() * kinds.length) | 0];
      if (kind === 'copy' || kind === 'two' || kind === 'gather') return wFresh(kind, [1024, 32768, 102400, 1048576][(Math.random() * 4) | 0]);
      const [n, b] = SHAPES[(Math.random() * 4) | 0];
      return pStream(kind, n, b);
    };
    await new Promise((resolve) => {
      for (let i = 0; i < conns; i++) {
        open++;
        let finished = false;
        const c = conn((e, err) => {
          if (err) { bad++; first = first || `${e ? e.path : '?'}: ${err}`; } else ok++;
          if (!err && Date.now() < end) c.send(next()); else { finished = true; c.sock.destroy(); }
        }, (e, se) => { if (!finished) { early++; first = first || `connection closed early${se ? ' (' + se + ')' : ''}`; } bytes += c.bytes(); if (--open === 0) resolve(); });
        c.sock.on(TLS ? 'secureConnect' : 'connect', () => c.send(next()));
      }
    });
    console.log(`load ${secs}s x${conns} conns kinds=${kinds}: responses=${ok + bad} ok=${ok} corrupt=${bad} closed_early=${early} dup_seq=${dupSeq} MB=${(bytes / 1048576) | 0}${first ? ' first_bad=' + first : ''}`);
    process.exit(bad || early || dupSeq ? 1 : 0);
  } else if (cmd === 'disconnect') {
    const kind = args[0], times = +args[1], par = 20;
    let started = 0, finished = 0, got = 0, errs = 0, short = 0;
    await new Promise((resolve) => {
      const one = () => {
        if (started >= times) return;
        started++;
        const sock = connect(); let n = 0, closed = false;
        sock.on(TLS ? 'secureConnect' : 'connect', () => sock.write(req(`/p/${kind}/400/65536`)));
        sock.on('data', (d) => { n += d.length; if (n >= 65536) sock.destroy(); });
        sock.on('error', (e) => { if (e.code !== 'ECONNRESET' && e.code !== 'EPIPE') errs++; });
        sock.on('close', () => { if (closed) return; closed = true; got += n; if (n < 65536) short++; if (++finished === times) resolve(); else one(); });
      };
      for (let i = 0; i < par; i++) one();
    });
    console.log(`disconnect ${kind}: ${short || errs ? 'FAIL' : 'OK'} ${times} streams of 400x64K dropped by the client after 64 KB (avg bytes read ${(got / times) | 0}, ended before 64 KB: ${short}, socket errors: ${errs})`);
    process.exit(short || errs ? 1 : 0);
  } else if (cmd === 'slow') {
    const [kind, n, b, kbps, secs] = [args[0], +args[1], +args[2], +args[3], +args[4]];
    const e = pStream(kind, n, b);
    const t0 = Date.now();
    const res = await new Promise((resolve) => {
      const c = conn((x, err) => { clearInterval(iv); c.sock.destroy(); resolve(err || 'ok'); }, () => resolve('closed early'));
      setTimeout(() => { clearInterval(iv); resolve(`no end of stream after 25 s (${c.bytes()} bytes read)`); c.sock.destroy(); }, 25000);
      // Read in bursts: pause, and let through roughly kbps for the first secs.
      let fast = false;
      const iv = setInterval(() => {
        if (fast) return;
        if (Date.now() - t0 > secs * 1000) { fast = true; c.sock.resume(); return; }
        c.sock.resume(); setTimeout(() => { if (!fast) c.sock.pause(); }, 1);
      }, 250);
      c.sock.on(TLS ? 'secureConnect' : 'connect', () => { c.sock.setNoDelay(true); c.send(e); c.sock.pause(); });
      void kbps;
    });
    console.log(`slow ${kind} ${n}x${b}: ${res === 'ok' ? 'OK' : 'FAIL ' + res} after ${((Date.now() - t0) / 1000).toFixed(1)}s`);
    process.exit(res === 'ok' ? 0 : 1);
  }
})();
