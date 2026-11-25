#!/usr/bin/env python3
"""Facil.jl vs Node.js scoreboard: runs the rows in rows.json and prints facil/Node ratios.
See run.sh --help. Python 3.9 stdlib only."""
import argparse, datetime, http.client, json, os, re, resource, shutil, signal, statistics, subprocess, sys, threading, time

S = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(S))
BIN, DATA, NODE_DIR = os.path.join(S, 'bin'), os.path.join(S, 'data'), os.path.join(S, 'node')
FACIL_ENV = os.path.join(S, 'facil')
AUTOCANNON = os.path.join(NODE_DIR, 'node_modules', '.bin', 'autocannon')
PORTS = {'node': 3510, 'facil': 3520}
NODE_SCRIPTS = {'http': 'http_server.js', 'uws': 'uws_server.js', 'ws': 'ws_server.js', 'https': 'https_server.js'}
OPPONENT = {'http': 'node:http', 'uws': 'uWebSockets.js', 'ws': 'ws', 'https': 'node:https'}
STARTED = {}  # pid -> Popen, every process group this driver created
FACIL_ENV_DEFAULTS = {'JULIA_NUM_GC_THREADS': '4'}
FACIL_ENV_VARS = dict(FACIL_ENV_DEFAULTS)


class CellError(Exception):
    pass


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def sh(*a, timeout=60):
    return subprocess.run(a, capture_output=True, text=True, timeout=timeout)


# ---------- processes ----------

def listeners(port):
    return set(sh('lsof', '-nP', '-t', f'-iTCP:{port}', '-sTCP:LISTEN').stdout.split())


def children(pid):
    out = set()
    todo = [str(pid)]
    while todo:
        p = todo.pop()
        for c in sh('pgrep', '-P', p).stdout.split():
            if c not in out:
                out.add(c)
                todo.append(c)
    return out


def tree(pid):
    return [str(pid)] + sorted(children(pid))


def ps_sum(pids, field):
    if not pids:
        return 0.0
    out = sh('ps', '-o', f'{field}=', '-p', ','.join(pids)).stdout.split()
    if field == 'rss':
        return sum(int(x) for x in out) / 1024
    tot = 0.0
    for t in out:
        days = 0
        if '-' in t:
            d, t = t.split('-')
            days = int(d)
        s = 0.0
        for x in t.split(':'):
            s = s * 60 + float(x)
        tot += s + days * 86400
    return tot


def cpu_s(pid):
    return ps_sum(tree(pid), 'time')


def rss_mb(pid):
    return ps_sum(tree(pid), 'rss')


def stop(proc):
    if proc.poll() is None:
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            proc.wait(5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait()
    STARTED.pop(proc.pid, None)


def stop_all(*_):
    for p in list(STARTED.values()):
        stop(p)


def run_client(cmd, timeout, env=None):
    """Runs one client to completion; returns (stdout, cpu seconds, wall seconds) from its own rusage."""
    import tempfile
    t0 = time.time()
    f = tempfile.TemporaryFile('w+', dir=OUT)
    e = tempfile.TemporaryFile('w+', dir=OUT)
    p = subprocess.Popen(cmd, stdout=f, stderr=e, text=True, env=env, start_new_session=True)
    STARTED[p.pid] = p
    deadline = t0 + timeout
    while True:
        pid, status, ru = os.wait4(p.pid, os.WNOHANG)
        if pid:
            break
        if time.time() > deadline:
            os.killpg(p.pid, signal.SIGKILL)
            pid, status, ru = os.wait4(p.pid, 0)
            break
        time.sleep(0.02)
    p.returncode = os.waitstatus_to_exitcode(status) if hasattr(os, 'waitstatus_to_exitcode') else status
    STARTED.pop(p.pid, None)
    f.seek(0)
    e.seek(0)
    out, err = f.read(), e.read()
    f.close()
    e.close()
    return out, ru.ru_utime + ru.ru_stime, time.time() - t0, err


def idle_pct():
    out = sh('top', '-l', '2', '-n', '0', '-s', '1').stdout
    m = re.findall(r'([\d.]+)% idle', out)
    return float(m[-1]) if m else 0.0


def wait_idle():
    t0 = time.time()
    while True:
        i = idle_pct()
        if i >= ARGS.idle_min or time.time() - t0 > ARGS.idle_wait:
            return i, os.getloadavg()[0]
        log(f'    machine {i:.0f}% idle (< {ARGS.idle_min}), waiting')
        time.sleep(5)


class Sampler(threading.Thread):
    def __init__(self, pid):
        super().__init__(daemon=True)
        self.pid, self.peak, self.halt = pid, 0.0, threading.Event()

    def run(self):
        while not self.halt.is_set():
            try:
                self.peak = max(self.peak, rss_mb(self.pid))
            except Exception:
                pass
            self.halt.wait(0.25)

    def done(self):
        self.halt.set()
        self.join()
        return self.peak


# ---------- servers ----------

JULIA = None


def julia_bin():
    global JULIA
    if JULIA is None:
        JULIA = sh('julia', '-e', 'print(joinpath(Sys.BINDIR, "julia"))').stdout.strip()
    return JULIA


def facil_status():
    if not os.path.exists(os.path.join(REPO, 'src', 'Facil.jl')):
        return 'not built'
    try:
        r = sh(julia_bin(), f'--project={FACIL_ENV}', '-e', 'using Facil, JSON; isdefined(Facil, :serve) || exit(3)', timeout=900)
    except subprocess.TimeoutExpired:
        return 'not built'
    if r.returncode:
        log('\n'.join(r.stderr.strip().splitlines()[:3]))
        log(f'`using Facil, JSON` failed in {FACIL_ENV}; run Pkg.instantiate() there once Facil loads')
        return 'not built'
    return None


def server_cmd(side, spec, port):
    if side == 'node':
        kind = spec.get('server', 'http')
        args = ['node', os.path.join(NODE_DIR, NODE_SCRIPTS[kind]), str(port)]
        if kind == 'https':
            cert = spec.get('cert', 'rsa')
            args += [os.path.join(DATA, f'{cert}_cert.pem'), os.path.join(DATA, f'{cert}_key.pem')]
        args += spec.get('args', [])
        env = dict(os.environ, **{k: str(v) for k, v in spec.get('env', {}).items()})
        if spec.get('workers', 1) > 1:
            env['WORKERS'] = str(spec['workers'])
        return args, env
    opts = dict(spec)
    threads = opts.pop('threads', 1)
    env = dict(os.environ, **{k: str(v) for k, v in opts.pop('env', {}).items()})
    if 'tls' in opts:
        opts['cert'] = os.path.join(DATA, f"{opts['tls']}_cert.pem")
        opts['key'] = os.path.join(DATA, f"{opts['tls']}_key.pem")
    sysimg = opts.pop('sysimage', None)
    args = [julia_bin(), f'-t{threads}', f'--project={FACIL_ENV}'] + ([f'--sysimage={os.path.join(FACIL_ENV, sysimg)}'] if sysimg else [])
    args += [os.path.join(FACIL_ENV, 'server.jl'), str(port)]
    args += [f'{k}={v}' for k, v in sorted(opts.items())]
    return args, env


def start_server(side, spec):
    port = PORTS[side]
    if listeners(port):
        raise CellError(f'port {port} already has a listener (pid {",".join(listeners(port))}); not ours, not touched')
    args, env = server_cmd(side, spec, port)
    logf = open(os.path.join(OUT, 'logs', f'{side}.server.log'), 'a')
    logf.write(f'\n=== {time.strftime("%H:%M:%S")} {" ".join(args)}\n')
    logf.flush()
    t0 = time.time()
    p = subprocess.Popen(args, env=env, stdout=logf, stderr=logf, start_new_session=True)
    STARTED[p.pid] = p
    while True:
        if p.poll() is not None:
            STARTED.pop(p.pid, None)
            raise CellError(f'{side} server exited at start (code {p.returncode}); see logs/{side}.server.log')
        owners = listeners(port)
        if owners:
            ours = {str(p.pid)} | children(p.pid)
            if not owners <= ours:
                stop(p)
                raise CellError(f'listener on {port} is {owners}, not the server we started ({p.pid})')
            break
        if time.time() - t0 > 300:
            stop(p)
            raise CellError(f'{side} server did not listen on {port} within 300 s')
        time.sleep(0.1)
    if spec.get('workers', 1) > 1:
        while len(children(p.pid)) < spec['workers'] and time.time() - t0 < 60:
            time.sleep(0.1)
        time.sleep(0.5)
    return p, time.time() - t0


def assert_owner(proc, side):
    owners = listeners(PORTS[side])
    if proc.poll() is not None:
        raise CellError(f'{side} server died')
    if not owners or not owners <= ({str(proc.pid)} | children(proc.pid)):
        raise CellError(f'listener on {PORTS[side]} is {owners or "none"}, not pid {proc.pid}')


# ---------- requests and probes ----------

def x_checksum(n):
    return f'{n} {120 * ((n + 1023) // 1024) + (120 if n else 0)}'


def gen_reqs():
    d = os.path.join(DATA, 'reqs')
    os.makedirs(d, exist_ok=True)
    H = 'Host: 127.0.0.1\r\n'
    reqs = {}
    for n in (2, 12, 40, 100):
        h = H + 'Accept: */*\r\n' + ''.join(f'X-Bench-Header-{i}: value-{i}-abcdefghijklmnopqrstuvwxyz\r\n' for i in range(3, n + 1))
        reqs[f'hdr_{n}'] = (f'GET /hdr HTTP/1.1\r\n{h}\r\n'.encode(), f'{n} 0')
    c, i = '', 0
    while len(c) < 4096:
        c += ('; ' if i else '') + f'c{i}=' + '0123456789abcdef' * 4
        i += 1
    reqs['cookie_4k'] = (f'GET /hdr HTTP/1.1\r\n{H}Accept: */*\r\nCookie: {c}\r\n\r\n'.encode(), f'3 {len(c)}')
    q, i = '', 0
    while len(q) < 2048:
        q += ('&' if i else '') + f'k{i}=value%20{i}+' + 'x' * 12
        i += 1
    reqs['query_2k'] = (f'GET /query?{q} HTTP/1.1\r\n{H}\r\n'.encode(), f'{q.count("&") + 1} value 7 {"x" * 12}')
    doc = {'id': 42, 'name': 'benchmark-user', 'email': 'bench@example.com', 'active': True, 'roles': ['admin', 'reviewer'], 'profile': {}, 'history': []}
    for i in range(6):
        doc['profile'][f'field{i}'] = 'value-' + 'p' * 20 + str(i)
    i = 0
    while len(json.dumps(doc, separators=(',', ':'))) < 1000:
        doc['history'].append({'at': 1700000000 + i, 'action': 'login', 'ok': i % 2 == 0})
        i += 1
    b = json.dumps(doc, separators=(',', ':')).encode()
    reqs['parse_1k'] = (f'POST /parse HTTP/1.1\r\n{H}Content-Type: application/json\r\nContent-Length: {len(b)}\r\n\r\n'.encode() + b, 'benchmark-user')
    body = b'{"msg":"hello from the echo benchmark","n":12345}'
    reqs['echo'] = (f'POST /echo HTTP/1.1\r\n{H}x-echo: 1\r\nContent-Type: application/octet-stream\r\nContent-Length: {len(body)}\r\n\r\n'.encode() + body, body.decode())
    for name, (raw, _) in reqs.items():
        with open(os.path.join(d, name + '.req'), 'wb') as f:
            f.write(raw)
    return reqs


def raw_request(port, raw, tls=False, timeout=30):
    import socket, ssl
    s = socket.create_connection(('127.0.0.1', port), timeout=timeout)
    if tls:
        ctx = ssl.create_default_context()
        ctx.check_hostname, ctx.verify_mode = False, ssl.CERT_NONE
        s = ctx.wrap_socket(s)
    s.sendall(raw)
    resp = http.client.HTTPResponse(s)
    resp.begin()
    body = resp.read()
    s.close()
    return resp.status, body, {k.lower(): v for k, v in resp.getheaders()}


def http_probe(port, p, tls=False):
    """One request shaped like the load; checks status and body so a broken endpoint never gets benchmarked."""
    if p.get('req'):
        raw, expect = REQS[p['req']]
        st, body, _ = raw_request(port, raw)
        if st != 200 or body.decode('latin1') != expect:
            raise CellError(f"probe {p['req']}: status {st}, body {body[:60]!r}, expected {expect[:60]!r}")
        return
    path = p.get('path', '/json')
    n = p.get('body')
    if n is None:
        raw = f'GET {path} HTTP/1.1\r\nHost: 127.0.0.1\r\n'
        for h in p.get('headers', []):
            raw += h + '\r\n'
        raw = (raw + '\r\n').encode()
    elif p.get('chunk'):
        k = p['chunk']
        parts = [f'{min(k, n - o):x}\r\n'.encode() + b'x' * min(k, n - o) + b'\r\n' for o in range(0, n, k)]
        raw = f'POST {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nTransfer-Encoding: chunked\r\n\r\n'.encode() + b''.join(parts) + b'0\r\n\r\n'
    else:
        raw = f'POST {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: {n}\r\n\r\n'.encode() + b'x' * n
    st, body, hdrs = raw_request(port, raw, tls=tls)
    if st != 200:
        raise CellError(f'probe {path}: status {st}')
    if n is not None and path.startswith('/upload') and body.decode() != x_checksum(n):
        raise CellError(f'probe {path}: body {body[:60]!r}, expected {x_checksum(n)!r}')
    if 'expect_len' in p and len(body) != p['expect_len']:
        raise CellError(f'probe {path}: {len(body)} body bytes, expected {p["expect_len"]}')
    if 'expect_encoding' in p and hdrs.get('content-encoding') != p['expect_encoding']:
        raise CellError(f'probe {path}: content-encoding {hdrs.get("content-encoding")}, expected {p["expect_encoding"]}')


def ws_probe(port, path='/echo'):
    out, _, _, err = run_client([os.path.join(BIN, 'wsbench'), 'echo', str(port), path, '1', '1', '64', 'text', '0', '0.3'], 20)
    try:
        r = json.loads(out)
    except ValueError:
        raise CellError(f'websocket probe failed: {err.strip()[:200]}')
    if r.get('connect_errors') or r.get('errors') or not r.get('msgs'):
        raise CellError(f'websocket probe failed: {out.strip()[:200]}')


# ---------- clients ----------

def quick(p):
    """--quick: short runs and at most three client processes or threads, for smoke checks only."""
    if not ARGS.quick:
        return p
    p = dict(p)
    for k, cap in (('dur', ARGS.quick_dur), ('prewarm', 1), ('warm', 0.5)):
        if k in p:
            p[k] = min(p[k], cap)
    for k in ('procs', 'workers', 'threads'):
        if k in p:
            p[k] = min(p[k], 3)
    return p


def lat_cmd(port, p, dur, warm):
    c = [os.path.join(BIN, 'lat'), '-P', str(port), '-d', str(dur), '-w', str(warm)]
    if p.get('req'):
        c += ['-f', os.path.join(DATA, 'reqs', p['req'] + '.req')]
    else:
        c += ['-u', p.get('path', '/json')]
        if p.get('body') is not None:
            c += ['-B', str(p['body'])]
            if p.get('chunk'):
                c += ['-k', str(p['chunk'])]
    for k, flag in (('pipeline', '-p'), ('rate', '-r')):
        if p.get(k):
            c += [flag, str(p[k])]
    return c


def run_lat(port, p, measure=True):
    procs = p.get('procs', 1)
    conns = p.get('conns', 100)
    per = max(1, conns // procs)
    dur = p.get('dur', 5) if measure else p.get('prewarm', 2)
    warm = p.get('warm', 1) if measure else 0
    settle = 0 if per < 500 else 1.0 + per * 0.0006
    rate = p.get('rate', 0)
    procs_out = []
    threads = []
    for i in range(procs):
        q = dict(p)
        if rate:
            q['rate'] = rate / procs
        cmd = lat_cmd(port, q, dur, warm) + ['-c', str(per)] + (['-s', f'{settle:.2f}'] if settle else [])
        t = threading.Thread(target=lambda c=cmd: procs_out.append(run_client(c, dur + warm + settle + 120)))
        threads.append(t)
        t.start()
    for t in threads:
        t.join()
    rs = []
    for out, cpu, wall, err in procs_out:
        try:
            rs.append(json.loads(out))
        except ValueError:
            raise CellError(f'lat failed: {(err or out).strip()[:200]}')
    errors = sum(r['non2xx'] + r['late_errors'] + r['stuck'] + r['bad_framing'] for r in rs)
    return {
        'rps': sum(r['rps'] for r in rs), 'n_all': sum(r['n_all'] for r in rs),
        'p50_ms': statistics.median(r['p50'] for r in rs), 'p99_ms': max(r['p99'] for r in rs),
        'p999_ms': max(r['p999'] for r in rs), 'max_ms': max(r['max'] for r in rs),
        'svc_p999_ms': max(r['svc_p999'] for r in rs), 'late_p999_ms': max(r['late_p999'] for r in rs),
        'errors': errors, 'conn_errors': sum(r['conn_errors'] for r in rs), 'connect_retries': sum(r['connect_retries'] for r in rs),
        'client_busy': max(r['client_cpu'] / max(r['wall'], 1e-9) for r in rs), 'client_procs': procs,
        'window_s': dur + warm,
    }


def run_autocannon(port, p, measure=True):
    dur = p.get('dur', 5) if measure else p.get('prewarm', 2)
    w = p.get('workers', 0)
    cmd = [AUTOCANNON, '-c', str(p.get('conns', 100)), '-d', str(dur), '-j']
    if w:
        cmd += ['-w', str(w)]
    if p.get('pipeline'):
        cmd += ['-p', str(p['pipeline'])]
    for h in p.get('headers', []):
        cmd += ['-H', h]
    if p.get('body') is not None:
        cmd += ['-m', 'POST', '-b', 'x' * p['body']]
    cmd.append(f"http://127.0.0.1:{port}{p.get('path', '/json')}")
    out, cpu, wall, err = run_client(cmd, dur + 120)
    try:
        r = json.loads(out)
    except ValueError:
        raise CellError(f'autocannon failed: {(err or out).strip()[:200]}')
    return {
        'rps': r['requests']['average'], 'n_all': r['requests']['total'],
        'p50_ms': r['latency']['p50'], 'p99_ms': r['latency']['p99'], 'max_ms': r['latency']['max'],
        'errors': r['errors'] + r['timeouts'] + r['non2xx'], 'client_busy': cpu / wall / max(w, 1),
        'client_procs': max(w, 1), 'window_s': dur, 'throughput_mb_s': r['throughput']['average'] / 1e6,
    }


def run_wsecho(port, p, measure=True):
    dur = p.get('dur', 4) if measure else p.get('prewarm', 1)
    warm = p.get('warm', 1) if measure else 0
    th = p.get('threads', 3)
    env = dict(os.environ)
    if p.get('payload'):
        env['WSB_PAYLOAD_FILE'] = os.path.join(DATA, p['payload'])
    if p.get('deflate'):
        env['WSB_DEFLATE_FRAME'] = os.path.join(DATA, p['deflate'])
    cmd = [os.path.join(BIN, 'wsbench'), 'echo', str(port), '/echo', str(p['conns']), str(th), str(p['size']), p.get('kind', 'bin'), str(warm), str(dur)]
    out, cpu, wall, err = run_client(cmd, dur + warm + 120, env=env)
    try:
        r = json.loads(out)
    except ValueError:
        raise CellError(f'wsbench failed: {(err or out).strip()[:200]}')
    return {'msgs_per_s': r['rate'], 'n_all': r['msgs'], 'p50_ms': r.get('p50_us', 0) / 1000, 'p99_ms': r.get('p99_us', 0) / 1000,
            'errors': r['errors'] + r['connect_errors'], 'client_busy': cpu / wall / th, 'client_procs': th, 'window_s': dur + warm,
            'wire_bytes_per_msg': r.get('wire_bytes', 0) / max(r['msgs'], 1)}


def run_wsbcast(port, p, pid):
    """Subscribers split over `procs` wsbench processes; deliveries/s spans the first to the last delivery of any of them."""
    n = p['rate'] * p['secs']
    th, procs = p.get('threads', 3), p.get('procs', 1)
    urlopen(port, '/start?n=20&rate=1000&size=200')
    time.sleep(1)
    base = rss_mb(pid)
    readies = [os.path.join(OUT, f'ws.ready.{i}') for i in range(procs)]
    for f in readies:
        if os.path.exists(f):
            os.remove(f)
    res = [None] * procs
    threads = []
    for i in range(procs):
        subs = p['subs'] * (i + 1) // procs - p['subs'] * i // procs
        cmd = [os.path.join(BIN, 'wsbench'), 'sub', str(port), '/sub', str(subs), str(th), str(n), str(p['secs'] + 100), readies[i]]
        t = threading.Thread(target=lambda i=i, c=cmd: res.__setitem__(i, run_client(c, p['secs'] + 220)))
        threads.append(t)
        t.start()
    for _ in range(600):
        if all(os.path.exists(f) for f in readies):
            break
        time.sleep(0.1)
    time.sleep(1)
    samp = Sampler(pid)
    samp.start()
    c0, t0 = cpu_s(pid), time.time()
    urlopen(port, f"/start?n={n}&rate={p['rate']}&size={p.get('size', 200)}")
    for t in threads:
        t.join()
    secs = time.time() - t0
    peak = samp.done()
    rs = []
    for out, cpu, wall, err in res:
        try:
            rs.append(json.loads(out))
        except ValueError:
            raise CellError(f'wsbench sub failed: {(err or out).strip()[:200]}')
    srv = cpu_s(pid) - c0
    msgs = sum(r['msgs'] for r in rs)
    firsts = [r['first_ns'] for r in rs if r.get('first_ns')]
    span = (max(r['last_ns'] for r in rs) - min(firsts)) / 1e9 if firsts else 0.0
    return {'deliveries_per_s': msgs / max(span, 1e-9), 'n_all': msgs, 'secs_to_deliver': span,
            'p50_ms': statistics.median(r.get('p50_us', 0) for r in rs) / 1000, 'p99_ms': max(r.get('p99_us', 0) for r in rs) / 1000,
            'errors': sum(r['errors'] + r['connect_errors'] + (r.get('expected', r['msgs']) - r['msgs']) for r in rs),
            'client_busy': max(x[1] / max(r['secs'], 1e-9) / th for x, r in zip(res, rs)), 'client_procs': procs * th,
            'closed_by_server': sum(r.get('closed', 0) for r in rs), 'client_cpu_s': [round(x[1], 2) for x in res], 'client_secs': [r['secs'] for r in rs],
            'rss_growth_mb': peak - base, 'server_cpu_s': srv, 'window_s': secs, 'deliveries_per_cpu_s': msgs / max(srv, 1e-9)}


def run_wsidle(port, p, pid):
    time.sleep(2)
    base = rss_mb(pid)
    ready = os.path.join(OUT, 'ws.ready')
    if os.path.exists(ready):
        os.remove(ready)
    cmd = [os.path.join(BIN, 'wsbench'), 'idle', str(port), p.get('path', '/echo'), str(p['conns']), '1', ready]
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    STARTED[proc.pid] = proc
    for _ in range(600):
        if os.path.exists(ready):
            break
        time.sleep(0.1)
    time.sleep(4)
    r = rss_mb(pid)
    connected = open(ready).read().split() if os.path.exists(ready) else ['0', str(p['conns'])]
    stop(proc)
    return {'bytes_per_conn': (r - base) * 1024 * 1024 / p['conns'], 'errors': int(connected[1]), 'rss_mb': r, 'client_busy': 0, 'client_procs': 1}


def run_tls(port, p, pid, measure=True):
    tl = os.path.join(BIN, 'tlsload')
    if not os.path.exists(tl):
        raise CellError('tlsload not built (no OpenSSL headers at build time)')
    th = p.get('threads', 3)
    if p['mode'] == 'ka':
        dur = p.get('dur', 5) if measure else p.get('prewarm', 1)
        cmd = [tl, 'ka', str(port), p['path'], str(p['conns']), str(th), str(p.get('warm', 1)), str(dur)]
    else:
        dur = p.get('dur', 4) if measure else 1
        th = p['conns']
        cmd = [tl, 'hs', str(port), str(th), str(p.get('warm', 0.3)), str(dur)] + (['resume'] if p.get('resume') else []) + [f"max={p.get('max', 6000)}"]
    out, cpu, wall, err = run_client(cmd, dur + 120)
    try:
        r = json.loads(out)
    except ValueError:
        raise CellError(f'tlsload failed: {(err or out).strip()[:200]}')
    return {'rps': r['rate'], 'n_all': r['all'], 'errors': r['errors'], 'client_busy': cpu / max(wall, 1e-9) / max(th, 1),
            'client_procs': th, 'window_s': wall}


def run_conn(port, p, pid):
    m = p['mode']
    cmd = ['node', os.path.join(S, 'clients', 'conn_client.js'), m, str(port)]
    if m == 'closeper':
        cmd += [str(p['conc']), str(p['amount']), str(p.get('workers', 2))]
    elif m == 'churn':
        cmd += [str(p['conc']), str(p['amount']), str(p['perconn']), str(p.get('workers', 2))]
    elif m == 'slowloris':
        cmd += [str(p['n']), str(p['secs'])]
    elif m == 'slowread':
        cmd += [str(p['n']), str(p['secs']), str(pid), str(p.get('pipeline', 1))]
    env = dict(os.environ, RST='1') if p.get('rst') else None
    t0 = time.time()
    out, cpu, wall, err = run_client(cmd, p.get('secs', 60) + 600, env=env)
    try:
        r = json.loads(out)
    except ValueError:
        raise CellError(f'conn_client {m} failed: {(err or out).strip()[:200]}')
    w = p.get('workers', 1) if m in ('closeper', 'churn') else 1
    res = {'client_busy': cpu / max(wall, 1e-9) / w, 'client_procs': w, 'window_s': time.time() - t0, 'raw': r}
    if m in ('closeper', 'churn'):
        res.update(rps=r['rps'], n_all=r['ok'], p99_ms=r['p99'], errors=r['errors'], stalled=r['over900ms'])
    elif m == 'slowloris':
        res.update(held=r['stillOpen'], errors=0, held_max_s=r['heldSecsMax'])
    else:
        res.update(rss_growth_mb=r['rssPeakMB'] - r['rssBeforeMB'], dropped=r['droppedByServer'], errors=0)
    return res


def run_startup(side, spec):
    """Launch to first full response, then the first and later requests on that connection (fresh server)."""
    import socket
    port = PORTS[side]
    if listeners(port):
        raise CellError(f'port {port} already has a listener')
    args, env = server_cmd(side, spec, port)
    req = b'GET /json HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n'
    t0 = time.perf_counter()
    p = subprocess.Popen(args, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    STARTED[p.pid] = p
    try:
        while True:
            if p.poll() is not None:
                raise CellError('server exited at start')
            if time.perf_counter() - t0 > 120:
                raise CellError('no response within 120 s')
            try:
                s = socket.create_connection(('127.0.0.1', port), timeout=30)
                break
            except OSError:
                time.sleep(0.002)
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        lats = []
        for i in range(200):
            t = time.perf_counter()
            s.sendall(req)
            r = http.client.HTTPResponse(s)
            r.begin()
            r.read()
            lats.append((time.perf_counter() - t) * 1000)
            if i == 0:
                start_ms = (time.perf_counter() - t0) * 1000
        s.close()
        owners = listeners(port)
        if not owners <= ({str(p.pid)} | children(p.pid)):
            raise CellError(f'listener on {port} was {owners}, not the server we started')
    finally:
        stop(p)
    steady = sorted(lats[100:])
    return {'startup_ms': start_ms, 'first_req_ms': lats[0], 'second_req_ms': lats[1], 'steady_ms': steady[len(steady) // 2],
            'errors': 0, 'client_busy': 0, 'client_procs': 1}


def urlopen(port, path):
    import urllib.request
    return urllib.request.urlopen(f'http://127.0.0.1:{port}{path}', timeout=10).read()


# ---------- cells ----------

def run_once(row, side):
    spec = row[side]
    p = quick(row['params'])
    client = row['client']
    if client == 'startup':
        idle, load = wait_idle()
        r = run_startup(side, spec)
        r.update(idle_before=idle, load_before=load)
        return r
    idle, load = wait_idle()
    proc, start_s = start_server(side, spec)
    port = PORTS[side]
    try:
        if client in ('lat', 'autocannon'):
            http_probe(port, p)
        elif client.startswith('ws'):
            ws_probe(port, '/echo')
        elif client == 'tls':
            raw_request(port, b'GET /json HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n', tls=True)
        else:
            raw_request(port, b'GET /json HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n')
        if client == 'mem_idle':
            time.sleep(p.get('settle', 5))
            assert_owner(proc, side)
            return {'rss_mb': rss_mb(proc.pid), 'errors': 0, 'client_busy': 0, 'client_procs': 0, 'idle_before': idle, 'load_before': load}
        fn = {'lat': run_lat, 'autocannon': run_autocannon, 'wsecho': run_wsecho}.get(client)
        if fn:
            fn(port, p, measure=False)
        elif client == 'tls':
            run_tls(port, p, proc.pid, measure=False)
        time.sleep(0.5)
        assert_owner(proc, side)
        c0, t0 = cpu_s(proc.pid), time.time()
        samp = Sampler(proc.pid)
        samp.start()
        if fn:
            r = fn(port, p)
        elif client == 'tls':
            r = run_tls(port, p, proc.pid)
        elif client == 'wsbcast':
            r = run_wsbcast(port, p, proc.pid)
        elif client == 'wsidle':
            r = run_wsidle(port, p, proc.pid)
        elif client == 'conn':
            r = run_conn(port, p, proc.pid)
        else:
            raise CellError(f'unknown client {client}')
        wall = time.time() - t0
        r['rss_max_mb'] = samp.done()
        srv = cpu_s(proc.pid) - c0
        assert_owner(proc, side)
        r.update(server_cpu_s=srv, server_cores=srv / max(wall, 1e-9), idle_before=idle, load_before=load, start_s=start_s)
        if r.get('n_all'):
            r['cpu_us_per_req'] = srv / r['n_all'] * 1e6
            r['req_per_cpu_s'] = r['n_all'] / max(srv, 1e-9)
        return r
    finally:
        stop(proc)
        time.sleep(0.3)


def cell_key(row, side):
    return json.dumps([row['client'], row['params'], row[side]], sort_keys=True)


# ---------- table ----------

def fmt(x):
    if x is None:
        return '-'
    if abs(x) >= 1000:
        return f'{x:,.0f}'
    if abs(x) >= 100:
        return f'{x:.0f}'
    if abs(x) >= 10:
        return f'{x:.1f}'
    if abs(x) >= 1:
        return f'{x:.2f}'
    return f'{x:.3g}'


def summary(vals):
    if not vals:
        return None, '-'
    med = statistics.median(vals)
    s = fmt(med)
    if len(vals) > 1:
        s += f' ({fmt(min(vals))}–{fmt(max(vals))})'
    return med, s


def ratio_of(row, f, n):
    if f is None or n is None:
        return None
    a, b = (f, n) if row['better'] == 'higher' else (n, f)
    if b == 0:
        return 1.0 if a == 0 else float('inf')
    return a / b


def verdict(row, ratio, flags):
    if ratio is None:
        return '-'
    t = row['target']
    if 'busy' in flags:
        return 'NOISY'
    if ratio >= (t if isinstance(t, (int, float)) else 1.0):
        return 'PASS'
    return 'EXCEPTION' if row.get('exception') or t == 'exception candidate' else 'FAIL'


def side_cell(row, runs, status):
    if status:
        return None, status, set()
    ok = [r for r in runs if 'error' not in r]
    if not ok:
        return None, 'error: ' + (runs[0]['error'] if runs else 'no runs'), set()
    vals = [r[row['metric']] for r in ok if row['metric'] in r]
    med, s = summary(vals)
    flags = set()
    if any(r.get('client_busy', 0) >= 0.9 for r in ok):
        flags.add('client')
    if any(r.get('idle_before', 100) < ARGS.idle_min for r in ok):
        flags.add('busy')
    if any(r.get('errors', 0) for r in ok):
        flags.add('errors')
    if len(ok) < len(runs):
        flags.add('failed runs')
    return med, s, flags


def write_table(rows, results, facil_state, path):
    lines = [f'# Facil.jl vs Node.js scoreboard — {RUN_ID}', '',
             f'runs per cell: {ARGS.runs}{"; QUICK (short runs, client capped at 3 procs/threads: indicative only)" if ARGS.quick else ""}; sides: {ARGS.side}; '
             f'machine: {os.cpu_count()} cores; node {sh("node", "--version").stdout.strip()}'
             f'; facil env: {" ".join(f"{k}={v}" for k, v in sorted(FACIL_ENV_VARS.items()))}', '',
             'Cells: median (min–max). ratio = facil/node for higher-is-better metrics, node/facil for lower-is-better, so >1 favours facil.',
             'Flags: client = load client reached 90% of its cores (number is a lower bound); busy = machine under the idle bar before a run '
             '(verdict NOISY); errors = non-2xx/reset/stuck responses seen.', '',
             '| row | name | metric | facil | node | ratio | target | verdict | opponent | node (validation) | flags |',
             '|---|---|---|---|---|---|---|---|---|---|---|']
    for row in rows:
        res = results.get(row['id'], {})
        fm, fs, ff = side_cell(row, res.get('facil', []), facil_state if 'facil' in SIDES else 'not run')
        nm, ns, nf = side_cell(row, res.get('node', []), None if 'node' in SIDES else 'not run')
        r = ratio_of(row, fm, nm)
        flags = sorted({f'facil:{x}' for x in ff} | {f'node:{x}' for x in nf})
        allf = ff | nf
        v = verdict(row, r, allf)
        val = row.get('validation', {}).get('node')
        unit = row['metric']
        lines.append(f"| {row['id']} | {row['name']} | {unit} ({'↑' if row['better'] == 'higher' else '↓'}) | {fs} | {ns} | "
                     f"{fmt(r) + '×' if r is not None else '-'} | {row['target'] if isinstance(row['target'], str) else '≥' + str(row['target'])} | "
                     f"{v} | {opponent(row)} | {fmt(val) if isinstance(val, (int, float)) else '-'} | {', '.join(flags)} |")
    excs = [r for r in rows if r.get('exception')]
    if excs:
        lines += ['', 'EXCEPTION = under target on a row with an approved exception:', '']
        lines += [f"- {r['id']}: {r['exception']}" for r in excs]
    with open(path, 'w') as f:
        f.write('\n'.join(lines) + '\n')
    return '\n'.join(lines)


def opponent(row):
    n = row['node']
    o = OPPONENT[n.get('server', 'http')]
    if n.get('workers', 1) > 1:
        o = f"cluster W={n['workers']}"
    return o


# ---------- main ----------

def main():
    global ARGS, OUT, RUN_ID, REQS, SIDES, FACIL_ENV_VARS
    ap = argparse.ArgumentParser(prog='run.sh', description=__doc__)
    ap.add_argument('--rows', help='comma-separated row ids (default: all)')
    ap.add_argument('--runs', type=int, default=3)
    ap.add_argument('--side', choices=['node', 'facil', 'both'], default='both')
    ap.add_argument('--quick', action='store_true', help='short durations and at most 3 client processes or threads (smoke check)')
    ap.add_argument('--quick-dur', type=float, default=2.0)
    ap.add_argument('--idle-min', type=float, default=90.0, help='required %% idle CPU before each run (default 90)')
    ap.add_argument('--idle-wait', type=float, default=120.0, help='seconds to wait for the machine to go idle')
    ap.add_argument('--list', action='store_true', help='print the rows and exit')
    ap.add_argument('--resume', help='results directory to continue: keeps its successful runs, appends the missing ones to its raw.jsonl')
    ap.add_argument('--facil-env', action='append', default=[], metavar='KEY=VAL',
                    help='environment variable for every Facil server (repeatable; default JULIA_NUM_GC_THREADS=4, '
                         'which this overrides by key); recorded in the table header')
    ARGS = ap.parse_args()
    rows = json.load(open(os.path.join(S, 'rows.json')))['rows']
    FACIL_ENV_VARS = {**FACIL_ENV_DEFAULTS, **dict(kv.split('=', 1) for kv in ARGS.facil_env)}
    cli = dict(kv.split('=', 1) for kv in ARGS.facil_env)
    for r in rows:
        r['facil'] = dict(r['facil'], env={**FACIL_ENV_DEFAULTS, **r['facil'].get('env', {}), **cli})
    if ARGS.list:
        for r in rows:
            print(f"{r['id']:8} {r['client']:10} {r['metric']:16} {r['name']}")
        return
    if ARGS.rows:
        want = ARGS.rows.split(',')
        unknown = [w for w in want if w not in {r['id'] for r in rows}]
        if unknown:
            sys.exit(f'unknown row ids: {unknown}')
        rows = [r for r in rows if r['id'] in want]
    SIDES = ['node', 'facil'] if ARGS.side == 'both' else [ARGS.side]
    for b in ('lat', 'wsbench'):
        if not os.path.exists(os.path.join(BIN, b)):
            sys.exit(f'{b} not built: run bench/scoreboard/build.sh')
    prior = {}
    if ARGS.resume:
        OUT = os.path.abspath(ARGS.resume)
        RUN_ID = os.path.basename(OUT)
        for line in open(os.path.join(OUT, 'raw.jsonl')):
            r = json.loads(line)
            if 'error' not in r:
                prior.setdefault((r['row'], r['side']), []).append(r)
    else:
        RUN_ID = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
        OUT = os.path.join(S, 'results', RUN_ID)
    os.makedirs(os.path.join(OUT, 'logs'), exist_ok=True)
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    resource.setrlimit(resource.RLIMIT_NOFILE, (min(hard, 60000) if hard != resource.RLIM_INFINITY else 60000, hard))
    signal.signal(signal.SIGTERM, lambda *a: sys.exit(143))
    REQS = gen_reqs()
    facil_state = None
    if 'facil' in SIDES:
        facil_state = facil_status()
        if facil_state:
            log(f'Facil not built: needs {REPO}/src/Facil.jl with a working `serve`, loadable in {FACIL_ENV}; the facil column is marked "not built"')
    raw = open(os.path.join(OUT, 'raw.jsonl'), 'a' if ARGS.resume else 'w')
    results, cache = {}, {}
    try:
        for row in rows:
            log(f"== {row['id']}: {row['name']}")
            res = results.setdefault(row['id'], {})
            todo = []
            for side in SIDES:
                if side == 'facil' and facil_state:
                    continue
                key = cell_key(row, side)
                if key in cache:
                    log(f'   {side}: same measurement as row {cache[key][0]["row"] if cache[key] else "?"}, reusing its runs')
                else:
                    cache[key] = list(prior.get((row['id'], side), []))
                    todo.append(side)
                res[side] = cache[key]
            for rep in range(ARGS.runs):
                for side in todo:
                    if rep < len(prior.get((row['id'], side), [])):
                        continue
                    t0 = time.time()
                    try:
                        r = run_once(row, side)
                    except CellError as e:
                        r = {'error': str(e)}
                    except Exception as e:
                        r = {'error': f'{type(e).__name__}: {e}'}
                    r.update(row=row['id'], side=side, rep=rep + 1, secs=round(time.time() - t0, 1))
                    res[side].append(r)
                    raw.write(json.dumps(r) + '\n')
                    raw.flush()
                    m = r.get(row['metric'])
                    log(f"   rep {rep + 1} {side:5}: {row['metric']}={fmt(m) if isinstance(m, (int, float)) else r.get('error')} "
                        f"client-busy={r.get('client_busy', 0):.2f} idle={r.get('idle_before', 0):.0f}% ({r['secs']} s)")
            write_table(rows, results, facil_state, os.path.join(OUT, 'table.md'))
    finally:
        stop_all()
        raw.close()
    print(write_table(rows, results, facil_state, os.path.join(OUT, 'table.md')))
    log(f'\nresults: {OUT}/table.md, raw runs: {OUT}/raw.jsonl')


if __name__ == '__main__':
    main()
