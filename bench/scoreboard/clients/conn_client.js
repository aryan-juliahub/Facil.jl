// Load shapes autocannon cannot produce. Prints one JSON line.
//   node client.js closeper  <port> <conc> <amount> [workers]
//   node client.js churn     <port> <conc> <amount> <perconn> [workers]   (RST=1 closes with a reset)
//   node client.js hold      <port> <n> <secs> <pid>        (one request per connection, then idle)
//   node client.js slowloris <port> <n> <secs>
//   node client.js slowread  <port> <n> <secs> <pid> [pipelined requests per connection]
const net = require('net');
const { execSync } = require('child_process');
const { Worker, isMainThread, workerData, parentPort } = require('worker_threads');

const argv = isMainThread ? process.argv.slice(2) : workerData.argv;
const [mode, portS, ...rest] = argv;
const port = parseInt(portS, 10);
const HOST = '127.0.0.1';
const now = () => Number(process.hrtime.bigint()) / 1e6;
const bump = (m, k) => { m[k] = (m[k] || 0) + 1; };
const pct = (a, p) => (a.length ? a[Math.min(a.length - 1, Math.floor(a.length * p))] : 0);

function ps(pid) {
  const [rss, time] = execSync(`ps -o rss=,time= -p ${pid}`).toString().trim().split(/\s+/);
  const cpu = time.split(':').reduce((s, x) => s * 60 + parseFloat(x), 0);
  return { rssMB: +(parseInt(rss, 10) / 1024).toFixed(1), cpu };
}

function fanOut(workers, split) {
  return Promise.all(Array.from({ length: workers }, (_, i) => new Promise((resolve, reject) => {
    const w = new Worker(__filename, { workerData: { argv: split(i) } });
    w.on('message', resolve).on('error', reject);
  })));
}

function merge(parts, t0) {
  const out = { ok: 0, conns: 0, errors: {}, lat: [] };
  for (const p of parts) {
    out.ok += p.ok; out.conns += p.conns;
    for (const k in p.errors) out.errors[k] = (out.errors[k] || 0) + p.errors[k];
    for (const x of p.lat) out.lat.push(x);
  }
  out.lat.sort((a, b) => a - b);
  const secs = (now() - t0) / 1000;
  return {
    ok: out.ok, conns: out.conns, secs: +secs.toFixed(3), rps: Math.round(out.ok / secs),
    errors: Object.values(out.errors).reduce((a, b) => a + b, 0), errorKinds: out.errors,
    p50: +pct(out.lat, 0.5).toFixed(2), p99: +pct(out.lat, 0.99).toFixed(2),
    maxMs: Math.round(out.lat[out.lat.length - 1] || 0), over900ms: out.lat.filter((x) => x > 900).length,
  };
}

// One connection per request; the server must be the one to close.
function closeper(conc, amount) {
  const REQ = 'GET /json HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n';
  const res = { ok: 0, conns: 0, errors: {}, lat: [] };
  let started = 0, live = conc;
  return new Promise((resolve) => {
    const next = () => {
      if (started >= amount) { if (--live === 0) resolve(res); return; }
      started++;
      const t = now();
      let got = 0, head = '', done = false;
      const s = net.connect(port, HOST);
      s.setTimeout(5000);
      const fin = (err) => {
        if (done) return; done = true;
        if (err) bump(res.errors, err); else { res.ok++; if (res.lat.length < 200000) res.lat.push(now() - t); }
        s.destroy();
        if (err === 'EADDRNOTAVAIL') setTimeout(next, 20); else next();
      };
      s.on('connect', () => { res.conns++; s.write(REQ); });
      s.on('data', (d) => { if (!got) head = d.toString('latin1', 0, 12); got += d.length; });
      s.on('end', () => fin(head === 'HTTP/1.1 200' && got > 150 ? null : 'short'));
      s.on('timeout', () => fin('timeout'));
      s.on('error', (e) => fin(e.code || 'error'));
    };
    for (let i = 0; i < conc; i++) next();
  });
}

// Keep-alive connections that the client closes after <perconn> requests.
function churn(conc, amount, perconn) {
  const REQ = Buffer.from('GET /json HTTP/1.1\r\nHost: x\r\n\r\n');
  const rst = process.env.RST === '1';
  const res = { ok: 0, conns: 0, errors: {}, lat: [] };
  let started = 0, live = conc, respLen = 0;
  return new Promise((resolve) => {
    const next = () => {
      if (started >= amount) { if (--live === 0) resolve(res); return; }
      let left = Math.min(perconn, amount - started);
      started += left;
      let got = 0, buf = '', done = false, t = 0;
      const s = net.connect(port, HOST);
      s.setNoDelay(true);
      s.setTimeout(5000);
      const fin = (err) => {
        if (done) return; done = true;
        if (err) bump(res.errors, err);
        if (rst) s.resetAndDestroy(); else s.destroy();
        if (err === 'EADDRNOTAVAIL') setTimeout(next, 20); else next();
      };
      const send = () => { t = now(); s.write(REQ); };
      s.on('connect', () => { res.conns++; send(); });
      s.on('data', (d) => {
        got += d.length;
        if (!respLen) {
          buf += d.toString('latin1');
          const i = buf.indexOf('\r\n\r\n');
          if (i < 0) return;
          const m = /content-length: *(\d+)/i.exec(buf);
          if (buf.length < i + 4 + parseInt(m[1], 10)) return;
          respLen = i + 4 + parseInt(m[1], 10);
        }
        while (got >= respLen && !done) {
          got -= respLen; res.ok++;
          if (res.lat.length < 100000) res.lat.push(now() - t);
          if (--left === 0) fin(null); else send();
        }
      });
      s.on('end', () => fin('server_closed'));
      s.on('timeout', () => fin('timeout'));
      s.on('error', (e) => fin(e.code || 'error'));
    };
    for (let i = 0; i < conc; i++) next();
  });
}

function openMany(n, onSocket) {
  const socks = [];
  const stats = { connected: 0, failed: {}, closedByServer: 0 };
  return new Promise((resolve) => {
    let i = 0, settled = 0;
    const step = () => {
      for (let k = 0; k < 100 && i < n; k++, i++) {
        const s = net.connect(port, HOST);
        s.idx = i; s.openAt = 0;
        let counted = false;
        const settle = () => { if (!counted) { counted = true; if (++settled === n) resolve({ socks, stats }); } };
        s.on('connect', () => { stats.connected++; s.openAt = now(); socks.push(s); onSocket(s, settle); });
        s.on('error', (e) => { if (!s.openAt) bump(stats.failed, e.code || 'error'); s.failed = true; settle(); });
        s.on('close', () => { if (s.openAt && !s.byUs) { stats.closedByServer++; s.closedAt = now(); } settle(); });
      }
      if (i < n) setTimeout(step, 10);
    };
    step();
  });
}

async function hold(n, secs, pid) {
  const REQ = 'GET /json HTTP/1.1\r\nHost: x\r\n\r\n';
  const { socks, stats } = await openMany(n, (s, settle) => {
    s.write(REQ);
    s.once('data', settle);
    s.on('data', () => {});
  });
  await new Promise((r) => setTimeout(r, 2000));
  const a = ps(pid), t0 = now();
  await new Promise((r) => setTimeout(r, secs * 1000));
  const b = ps(pid);
  const stillOpen = socks.filter((s) => !s.destroyed).length;
  socks.forEach((s) => { s.byUs = true; s.destroy(); });
  return { n, connected: stats.connected, connectErrors: stats.failed, stillOpen,
           rssMB: b.rssMB, cpuPct: +(100 * (b.cpu - a.cpu) / ((now() - t0) / 1000)).toFixed(2) };
}

// Request headers that never end, one byte every 10 ms per connection.
async function slowloris(n, secs) {
  const HEAD = 'GET /json HTTP/1.1\r\nHost: x\r\n';
  const LINE = 'X-Pad: aaaaaaaa\r\n';
  const { socks, stats } = await openMany(n, (s, settle) => {
    s.pos = 0; s.reply = '';
    s.on('data', (d) => { if (s.reply.length < 40) s.reply += d.toString('latin1'); });
    settle();
  });
  const t0 = now();
  const timeline = [];
  const tick = setInterval(() => {
    for (const s of socks) {
      if (s.destroyed || s.closedAt) continue;
      const c = s.pos < HEAD.length ? HEAD[s.pos] : LINE[(s.pos - HEAD.length) % LINE.length];
      s.pos++;
      s.write(c);
    }
  }, 10);
  const mark = setInterval(() => timeline.push([Math.round((now() - t0) / 1000), socks.filter((s) => !s.destroyed && !s.closedAt).length]), 10000);
  await new Promise((r) => setTimeout(r, secs * 1000));
  clearInterval(tick); clearInterval(mark);
  const held = socks.filter((s) => s.closedAt).map((s) => (s.closedAt - s.openAt) / 1000).sort((a, b) => a - b);
  const replies = {};
  socks.forEach((s) => bump(replies, s.reply.split('\r\n')[0] || '(none)'));
  const stillOpen = socks.filter((s) => !s.destroyed && !s.closedAt).length;
  const bytes = socks.map((s) => s.pos).sort((a, b) => a - b);
  socks.forEach((s) => { s.byUs = true; s.destroy(); });
  return { n, connected: stats.connected, stillOpen, closedByServer: held.length,
           heldSecsMin: +(held[0] || 0).toFixed(1), heldSecsMax: +(held[held.length - 1] || 0).toFixed(1),
           headerBytesSentMedian: pct(bytes, 0.5), replies, openEvery10s: timeline };
}

// Clients that ask for 1 MB and drain it at about 10 KB/s.
async function slowread(n, secs, pid, pipeline) {
  const before = ps(pid);
  const { socks, stats } = await openMany(n, (s, settle) => {
    s.got = 0;
    s.pause();
    s.write('GET /bytes/1048576 HTTP/1.1\r\nHost: x\r\n\r\n'.repeat(pipeline || 1));
    settle();
  });
  const drip = setInterval(() => {
    for (const s of socks) { const d = s.destroyed ? null : s.read(1024) || s.read(); if (d) s.got += d.length; }
  }, 100);
  const samples = [];
  const t0 = now();
  let peak = 0;
  const samp = setInterval(() => { const r = ps(pid).rssMB; peak = Math.max(peak, r); samples.push([Math.round((now() - t0) / 1000), r]); }, 2000);
  await new Promise((r) => setTimeout(r, secs * 1000));
  clearInterval(drip); clearInterval(samp);
  const stillOpen = socks.filter((s) => !s.destroyed).length;
  const got = socks.map((s) => s.got).sort((a, b) => a - b);
  socks.forEach((s) => { s.byUs = true; s.destroy(); });
  await new Promise((r) => setTimeout(r, 5000));
  return { n, connected: stats.connected, stillOpen, droppedByServer: stats.closedByServer, rssBeforeMB: before.rssMB, rssPeakMB: peak,
           rssAfterCloseMB: ps(pid).rssMB, clientGotMedianKB: Math.round(pct(got, 0.5) / 1024) };
}

async function main() {
  const nums = rest.map(Number);
  if (mode === 'closeper' || mode === 'churn') {
    const wIdx = mode === 'closeper' ? 2 : 3;
    const workers = nums[wIdx] || 1;
    const run = () => (mode === 'closeper' ? closeper(nums[0], nums[1]) : churn(nums[0], nums[1], nums[2]));
    if (!isMainThread) return parentPort.postMessage(await run());
    const t0 = now();
    if (workers === 1) return console.log(JSON.stringify(merge([await run()], t0)));
    const parts = await fanOut(workers, () => {
      const a = [mode, portS, String(Math.ceil(nums[0] / workers)), String(Math.ceil(nums[1] / workers))];
      if (mode === 'churn') a.push(String(nums[2]));
      return a;
    });
    return console.log(JSON.stringify(merge(parts, t0)));
  }
  if (mode === 'hold') return console.log(JSON.stringify(await hold(nums[0], nums[1], nums[2])));
  if (mode === 'slowloris') return console.log(JSON.stringify(await slowloris(nums[0], nums[1])));
  if (mode === 'slowread') return console.log(JSON.stringify(await slowread(nums[0], nums[1], nums[2], nums[3])));
  throw new Error('unknown mode');
}
main().then(() => { if (isMainThread) process.exit(0); });
