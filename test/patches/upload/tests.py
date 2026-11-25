#!/usr/bin/env python3
"""Correctness tests for the request-body path. Raw sockets, localhost only.
   tests.py <port> <group>[,<group>...] [modes]
   groups: sizes splits pipeline limits framing expect stall churn gc big1g
   modes:  string of route suffixes, '-' is the default plan (default: "-bvfst"; "-" only for stock)
Prints one line per case: PASS/FAIL/INFO name | proving line. Exit status 1 on any FAIL."""
import hashlib, os, random, socket, struct, subprocess, sys, threading, time

PORT = int(sys.argv[1])
GROUPS = sys.argv[2].split(',')
MODES = sys.argv[3] if len(sys.argv) > 3 else '-bvfst'
fails = 0
rnd = random.Random(7)


def out(ok, name, line):
    global fails
    tag = 'INFO' if ok is None else 'PASS' if ok else 'FAIL'
    if ok is False:
        fails += 1
    print(f'{tag} {name} | {line}', flush=True)


def conn(timeout=20):
    for attempt in range(20):
        try:
            s = socket.create_connection(('127.0.0.1', PORT), timeout=timeout)
            break
        except ConnectionResetError:
            # macOS loopback sometimes resets a connect that follows an RST close
            if attempt == 19:
                raise
            time.sleep(0.005)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    return s


def reset_close(s):
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', 1, 0))
    except OSError:
        pass
    s.close()


def read_responses(s, want=1, timeout=20, until_close=False):
    """Returns ([(status, body)], closed). Skips 1xx, which are returned as status entries too."""
    s.settimeout(timeout)
    buf = b''
    res = []
    closed = False
    while until_close or len([r for r in res if r[0] >= 200]) < want:
        while True:
            i = buf.find(b'\r\n\r\n')
            if i < 0:
                break
            head = buf[:i].decode('latin1')
            status = int(head.split(' ')[1])
            clen = 0
            for l in head.split('\r\n')[1:]:
                if l.lower().startswith('content-length:'):
                    clen = int(l.split(':')[1])
            if len(buf) < i + 4 + clen:
                break
            res.append((status, buf[i + 4:i + 4 + clen].decode('latin1')))
            buf = buf[i + 4 + clen:]
        if not until_close and len([r for r in res if r[0] >= 200]) >= want:
            break
        try:
            d = s.recv(65536)
        except socket.timeout:
            break
        except OSError:
            closed = True
            break
        if not d:
            closed = True
            break
        buf += d
    return res, closed


def route(op, mode):
    return f'/{op}' if mode == '-' else f'/{op}/{mode}'


def head_cl(path, n, extra=''):
    return f'POST {path} HTTP/1.1\r\nHost: t\r\nContent-Length: {n}\r\n{extra}\r\n'.encode()


def chunked_msg(path, body, sizes=None, ext=False, trailer=False, extra=''):
    parts = [f'POST {path} HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n{extra}\r\n'.encode()]
    o = 0
    k = 0
    while o < len(body):
        n = sizes[k % len(sizes)] if sizes else 16384
        c = body[o:o + n]
        e = f';n{k}=v{k};flag' if ext and k % 2 == 0 else ''
        parts += [f'{len(c):x}{e}\r\n'.encode(), c, b'\r\n']
        o += len(c)
        k += 1
    parts.append(b'0;last=1\r\n' if ext else b'0\r\n')
    if trailer:
        parts.append(b'X-Trailer: abc\r\nServer-Timing: x\r\n')
    parts.append(b'\r\n')
    return b''.join(parts)


def expect_sha(body):
    return f'{len(body)} {hashlib.sha256(body).hexdigest()}'


def one(msg, timeout=60):
    s = conn(timeout)
    try:
        s.sendall(msg)
        res, _ = read_responses(s, 1, timeout)
    except OSError as e:
        res = [(-1, str(e))]
    s.close()
    return res[-1] if res else (0, 'no response')


def stats():
    st, body = one(b'GET /stats HTTP/1.1\r\nHost: t\r\n\r\n')
    return dict(kv.split('=') for kv in body.split()) if st == 200 else {}


def alive():
    try:
        return one(b'GET /json HTTP/1.1\r\nHost: t\r\n\r\n', timeout=3)[0] == 200
    except OSError:
        return False


def g_sizes():
    sizes = [0, 1, 8191, 8192, 8193, 65536, 1 << 20, 50 << 20]
    for mode in MODES:
        bad = []
        n_ok = 0
        for n in sizes:
            body = os.urandom(n)
            want = expect_sha(body)
            variants = [('cl', head_cl(route('sha', mode), n) + body)]
            if n:
                variants.append(('chunked', chunked_msg(route('sha', mode), body, [65536, 1, 4093, 30000] if n > 100000 else [1000, 1, 7, 4096])))
                variants.append(('chunked+ext+trailer', chunked_msg(route('sha', mode), body, [65536, 17, 300000] if n > 100000 else [333, 1, 5000], ext=True, trailer=True)))
            for name, msg in variants:
                st, got = one(msg, 120)
                if st == 200 and got == want:
                    n_ok += 1
                else:
                    bad.append(f'{name} {n}: {st} {got[:40]}')
        out(not bad, f'sizes mode={mode}', f'{n_ok} sha256 matches over {sizes} x cl/chunked/chunked+ext+trailer, one segment' + (f'; BAD {bad[:4]}' if bad else ''))


def send_split(msg, cuts, gap=0.002, timeout=30):
    s = conn(timeout)
    prev = 0
    try:
        for c in cuts + [len(msg)]:
            if c > prev:
                s.sendall(msg[prev:c])
                prev = c
                time.sleep(gap)
        res, _ = read_responses(s, 1, timeout)
    except OSError as e:
        res = [(-1, str(e))]
    s.close()
    return res[-1] if res else (0, 'no response')


def g_splits():
    for mode in MODES:
        # every split point of a small message
        for kind in ('cl', 'chunked', 'chunked+ext+trailer'):
            body = bytes(rnd.randrange(256) for _ in range(120))
            msg = head_cl(route('sha', mode), len(body)) + body if kind == 'cl' else \
                chunked_msg(route('sha', mode), body, [50, 1, 30], ext=kind != 'chunked', trailer=kind != 'chunked')
            want = expect_sha(body)
            bad = [k for k in range(1, len(msg)) if send_split(msg, [k], 0.0015) != (200, want)]
            out(not bad, f'split-every-offset {kind} mode={mode}', f'{len(msg) - 1 - len(bad)}/{len(msg) - 1} two-segment splits correct' + (f'; BAD at {bad[:10]}' if bad else ''))
        # byte at a time, 20 KB
        for kind in ('cl', 'chunked'):
            body = os.urandom(20000)
            msg = head_cl(route('sha', mode), len(body)) + body if kind == 'cl' else chunked_msg(route('sha', mode), body, [7000, 3, 900])
            s = conn(60)
            t0 = time.time()
            try:
                for i in range(len(msg)):
                    s.send(msg[i:i + 1])
                    time.sleep(0.00002)
            except OSError as e:
                out(False, f'byte-at-a-time 20KB {kind} mode={mode}', f'server dropped the connection after {i} one-byte sends ({e.__class__.__name__})')
                s.close()
                continue
            res, _ = read_responses(s, 1, 60)
            s.close()
            ok = bool(res) and res[-1] == (200, expect_sha(body))
            out(ok, f'byte-at-a-time 20KB {kind} mode={mode}', f'{len(msg)} one-byte sends in {time.time() - t0:.1f}s -> {res[-1] if res else None}'[:150])
        # headers + partial body, and a cut at each byte of every chunk-size line of a 200 KB body
        body = os.urandom(200000)
        want = expect_sha(body)
        msg = head_cl(route('sha', mode), len(body)) + body
        h = msg.index(b'\r\n\r\n') + 4
        bad = [c for c in ([h], [h + 1], [h - 1], [h - 2], [h + 5000], [h, h + 8192, h + 65536], [8192], [8191], [8193], [65536]) if send_split(msg, c, 0.003) != (200, want)]
        out(not bad, f'headers+partial cl mode={mode}', f'10 cut patterns around header end / 8192 / 65536 correct' + (f'; BAD {bad}' if bad else ''))
        msg = chunked_msg(route('sha', mode), body, [40000, 9000, 70000])
        cuts = []
        pos = msg.index(b'\r\n\r\n') + 4
        o = 0
        for n in [40000, 9000, 70000, 40000, 9000, 32000]:
            line = len(f'{n:x}\r\n')
            cuts += [pos + d for d in range(0, line + 1)]
            pos += line + n
            cuts += [pos, pos + 1, pos + 2]
            pos += 2
        bad = [c for c in cuts if send_split(msg, [c], 0.003) != (200, want)]
        out(not bad, f'cut-at-chunk-size-line mode={mode}', f'{len(cuts) - len(bad)}/{len(cuts)} cuts inside/around chunk-size lines correct' + (f'; BAD {bad[:8]}' if bad else ''))


def g_pipeline():
    for mode in MODES:
        cases = []
        for name, sizes, kinds in (('cl+cl small', (300, 500), 'cc'), ('chunked+chunked', (300, 500), 'kk'), ('cl 20KB+cl 20KB', (20000, 20000), 'cc'),
                                   ('chunked 100KB+cl 100KB', (100000, 100000), 'kc'), ('cl 100KB+chunked 100KB+cl 5', (100000, 100000, 5), 'ckc'),
                                   ('cl 3MB + cl 3MB', (3 << 20, 3 << 20), 'cc')):
            bodies = [os.urandom(n) for n in sizes]
            msg = b''.join(head_cl(route('sha', mode), len(b)) + b if k == 'c' else chunked_msg(route('sha', mode), b, [30000, 11], trailer=True)
                           for b, k in zip(bodies, kinds)) + b'GET /json HTTP/1.1\r\nHost: t\r\n\r\n'
            s = conn(30)
            s.sendall(msg)
            res, _ = read_responses(s, len(bodies) + 1, 30)
            s.close()
            ok = len(res) == len(bodies) + 1 and all(r == (200, expect_sha(b)) for r, b in zip(res, bodies)) and res[-1][0] == 200 and res[-1][1].startswith('{"id"')
            cases.append((name, ok, [r[0] for r in res]))
        bad = [c for c in cases if not c[1]]
        out(not bad, f'pipelined POSTs in one write mode={mode}', f'{len(cases) - len(bad)}/{len(cases)} sequences answered in order with matching sha256 (+ trailing GET)' + (f'; BAD {bad}' if bad else ''))


def probe(name, msg, want_status, want_n=1, close_expected=True, note=''):
    """Sends msg, collects every response until the server closes (or 3 s)."""
    if any(k and k in name for k in os.environ.get('SKIP', '').split('|')):
        return
    if os.environ.get('ONLY') and os.environ['ONLY'] not in name:
        return
    s = conn(5)
    try:
        s.sendall(msg)
    except OSError:
        pass
    res, closed = read_responses(s, 99, 3, until_close=True)
    s.close()
    statuses = [r[0] for r in res]
    ok = None if want_status is None else (statuses == [want_status] * want_n and (closed or not close_expected))
    live = alive()
    if not live:
        ok = False
    out(ok, name, f'responses={statuses} bodies={[r[1][:24] for r in res]} closed_by_server={closed} server_alive_after={live} {note}')
    return statuses, closed


def g_framing():
    # A second request hidden where a lenient parser would find it.
    smug = b'GET /json HTTP/1.1\r\nHost: t\r\n\r\n'
    P = lambda h, body=b'': (f'POST /sha HTTP/1.1\r\nHost: t\r\n{h}\r\n').encode() + body
    probe('content-length negative', P('Content-Length: -5\r\n', b'hello' + smug), 400)
    probe('content-length non-numeric', P('Content-Length: abc\r\n', b'hello' + smug), 400)
    probe('content-length digits+junk', P('Content-Length: 5x\r\n', b'hello'), 400)
    probe('content-length with plus sign', P('Content-Length: +5\r\n', b'hello'), 400)
    probe('content-length empty', P('Content-Length: \r\n', smug), 400)
    probe('content-length 2^63', P('Content-Length: 9223372036854775808\r\n', b'hello'), 400)
    probe('content-length 2^64+5', P('Content-Length: 18446744073709551621\r\n', b'hello' + smug), 400)
    probe('content-length 30 digits', P('Content-Length: 100000000000000000000000000005\r\n', b'hello'), 400)
    probe('content-length duplicated, different', P('Content-Length: 5\r\nContent-Length: 6\r\n', b'hello!'), 400)
    probe('content-length duplicated, same (allowed)', P('Content-Length: 5\r\nContent-Length: 5\r\n', b'hello'), 200, close_expected=False)
    probe('content-length then chunked (smuggling)', P('Content-Length: 4\r\nTransfer-Encoding: chunked\r\n', b'0\r\n\r\n' + smug), 400)
    probe('chunked then content-length (smuggling)', P('Transfer-Encoding: chunked\r\nContent-Length: 4\r\n', b'0\r\n\r\n' + smug), 400)
    probe('transfer-encoding: chunked, identity', P('Transfer-Encoding: chunked, identity\r\n', b'5\r\nhello\r\n0\r\n\r\n'), 400)
    probe('transfer-encoding: identity', P('Transfer-Encoding: identity\r\n', smug), 400)
    probe('transfer-encoding: xchunked', P('Transfer-Encoding: xchunked\r\n', b'5\r\nhello\r\n0\r\n\r\n'), 400)
    probe('transfer-encoding twice', P('Transfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n', b'5\r\nhello\r\n0\r\n\r\n'), 400)
    probe('chunk size negative (-4)', P('Transfer-Encoding: chunked\r\n', b'-4\r\nabcd\r\n0\r\n\r\n'), 400)
    probe('chunk size 0x prefix', P('Transfer-Encoding: chunked\r\n', b'0x5\r\nhello\r\n0\r\n\r\n'), 400)
    probe('chunk size 17 hex digits', P('Transfer-Encoding: chunked\r\n', b'10000000000000005\r\nhello\r\n0\r\n\r\n'), 400)
    probe('chunk size with bare LF', P('Transfer-Encoding: chunked\r\n', b'5\nhello\r\n0\r\n\r\n'), 400)
    probe('chunk size missing', P('Transfer-Encoding: chunked\r\n', b'\r\nhello\r\n0\r\n\r\n'), 400)
    probe('chunk extension (valid)', P('Transfer-Encoding: chunked\r\n', b'5;a=b\r\nhello\r\n0\r\n\r\n'), 200, close_expected=False)
    probe('trailer after last chunk (valid)', P('Transfer-Encoding: chunked\r\n', b'5\r\nhello\r\n0\r\nX-T: 1\r\n\r\n'), 200, close_expected=False)
    probe('empty chunked body + Content-Length trailer', P('Transfer-Encoding: chunked\r\n', b'0\r\nContent-Length: 31\r\n\r\n' + smug), 200, want_n=2, close_expected=False,
          note='(2 responses = trailer not taken as a length; the GET is a real pipelined request)')


def g_limits():
    """Run against a server started with maxbody=1048576."""
    body = b'a' * (2 << 20)
    for mode in MODES:
        for kind in ('cl', 'chunked'):
            msg = head_cl(route('sha', mode), len(body)) + body if kind == 'cl' else chunked_msg(route('sha', mode), body, [65536])
            s = conn(10)
            t0 = time.time()
            sent = 0
            try:
                s.settimeout(3)
                while sent < len(msg):
                    sent += s.send(msg[sent:sent + 65536])
            except OSError:
                pass
            res, closed = read_responses(s, 99, 3, until_close=True)
            s.close()
            st = [r[0] for r in res]
            out(st == [413] and closed, f'body over max_body_size ({kind}) mode={mode}',
                f'responses={st} closed={closed} client managed to send {sent} of {len(msg)} bytes in {time.time() - t0:.2f}s')
    # a client that waits for the answer before sending the bulk
    s = conn(10)
    s.sendall(head_cl('/sha', 2 << 20) + b'a' * 1000)
    res, closed = read_responses(s, 99, 3, until_close=True)
    s.close()
    out([r[0] for r in res] == [413] and closed, 'over max_body_size, answered from the headers alone', f'responses={[r[0] for r in res]} closed={closed} after only 1000 body bytes were sent')
    s = conn(10)
    exact = os.urandom(1 << 20)
    st = one(head_cl('/sha', len(exact)) + exact)
    out(st == (200, expect_sha(exact)), 'body exactly max_body_size accepted', f'{st[0]} {st[1][:30]}')


def g_expect():
    for name, path, n, want in (('accepted', '/sha', 100000, 200), ('rejected by the headers hook', '/reject', 100000, 401),
                                ('over max_body_size', '/sha', 60 << 20, 413), ('small body', '/sha', 10, 200)):
        s = conn(10)
        body = os.urandom(n) if n <= 100000 else b''
        t0 = time.time()
        s.sendall(head_cl(path, n, 'Expect: 100-continue\r\n'))
        s.settimeout(1.5)
        try:
            first = s.recv(4096)
        except socket.timeout:
            first = b''
        dt = time.time() - t0
        line = first.split(b'\r\n')[0].decode()
        if first.startswith(b'HTTP/1.1 100'):
            s.sendall(body)
            res, closed = read_responses(s, 1, 10)
            final = res[-1] if res else (0, '')
            ok = want == 200 and final == (200, expect_sha(body))
            out(ok, f'expect-100 {name}', f'interim "{line}" after {dt * 1000:.0f} ms, then {final[0]} {final[1][:20]}')
        elif first:
            st = int(line.split(' ')[1])
            out(st == want and want != 200, f'expect-100 {name}', f'no interim response; final "{line}" after {dt * 1000:.0f} ms without sending the body')
        else:
            s.sendall(body)
            res, closed = read_responses(s, 1, 10)
            out(False if want == 200 else None, f'expect-100 {name}', f'nothing for {dt * 1000:.0f} ms (a real client stalls here until its own timer fires); after sending the body anyway: {[r[0] for r in res]}')
        s.close()
    r = subprocess.run(['curl', '-s', '-o', '/dev/null', '-w', '%{http_code} %{time_total}', '-H', 'Expect: 100-continue', '--data-binary', '@' + sys.argv[0],
                        f'http://127.0.0.1:{PORT}/sha'], capture_output=True, text=True)
    code, t = r.stdout.split()
    out(code == '200' and float(t) < 0.5, 'curl -H "Expect: 100-continue"', f'status {code} in {float(t) * 1000:.0f} ms (curl waits 1000 ms when no 100 arrives)')


def g_stall():
    """Run against a server started with timeout=3."""
    before = stats()
    conns = []
    for mode in MODES:
        s = conn(30)
        s.sendall(head_cl(route('sha', mode), 900000) + b'x' * 100000)
        conns.append((mode, s, time.time()))
    for mode, s, t0 in conns:
        s.settimeout(15)
        try:
            d = s.recv(4096)
            how = 'closed' if not d else d.split(b'\r\n')[0].decode()
        except socket.timeout:
            how = 'STILL OPEN after 15 s'
        except OSError as e:
            how = f'closed ({e.__class__.__name__})'
        out(how.startswith('closed'), f'short body then stall mode={mode}', f'900 KB promised, 100 KB sent: server {how} after {time.time() - t0:.1f}s (timeout=3)')
        s.close()
    time.sleep(0.5)
    after = stats()
    out(after.get('roots') == '0' and after.get('streams') == '0', 'stall: memory released', f'before {before} after {after}')


def tmpfiles():
    return len([f for f in os.listdir('/var/tmp') if f.startswith('facil_io_tmpfile_')])


def open_conns():
    pid = os.environ.get('SERVER_PID')
    if not pid:
        return -1
    r = subprocess.run(f"lsof -nP -p {pid} | grep TCP | grep -vc LISTEN", shell=True, capture_output=True, text=True)
    return int(r.stdout or 0)


def g_churn():
    """1000 clients per mode send part of a body and reset. Needs SERVER_PID and a server started with timeout=3.
    Phase A keeps the unsent data small, so the reset reaches the server: everything must be released at once.
    Phase B leaves the client with unsent data when it resets; macOS loopback then often never delivers the
    reset (a bare kqueue server shows the same), so release is checked after the connection timeout."""
    stats()
    base = stats()
    files0 = tmpfiles()
    for phase, sizes, wait in (('A small in-flight', [0, 1, 5000, 30000], 1.0), ('B large in-flight', [70000, 300000], 7.0)):
        for mode in MODES:
            t0 = time.time()
            for i in range(1000):
                s = conn(10)
                try:
                    if i % 2:
                        s.sendall(head_cl(route('sha', mode), 2 << 20) + b'y' * rnd.choice(sizes))
                    else:
                        s.sendall(chunked_msg(route('sha', mode), b'z' * (rnd.choice(sizes) + 1))[:-5])
                except OSError:
                    pass  # the kernel reset this connection before the request was written
                if i % 10 == 0:
                    time.sleep(0.002)
                reset_close(s)
            dt = time.time() - t0
            time.sleep(1.0)
            early = open_conns()
            time.sleep(wait - 1.0)
            left = open_conns()
            st = stats()
            grew = int(st.get('rss_kb', 0)) - int(base.get('rss_kb', 0))
            ok = st.get('roots', '0') == '0' and st.get('streams', '0') == '0' and tmpfiles() <= files0 and left == 0
            out(ok, f'1000 disconnects mid-body (RST) {phase} mode={mode}',
                f'{dt:.1f}s; open connections 1 s later: {early}, {wait:.0f} s later: {left}; roots={st.get("roots")} streams={st.get("streams")} aborts={st.get("aborts")} temp files {tmpfiles()}; rss {int(st.get("rss_kb", 0)) // 1024} MB ({grew // 1024:+d} MB vs start)')
    out(alive(), 'server alive after churn', 'GET /json 200')


def g_mv():
    """Spooled body handed over as a file: the handler renames it instead of reading it back."""
    files0 = tmpfiles()
    body = os.urandom(20 << 20)
    st = one(head_cl('/mv', len(body)) + body, 60)
    st2 = one(chunked_msg('/mv', body, [65536]), 60)
    out(st == (200, f'{len(body)} moved') and st2 == (200, f'{len(body)} moved') and tmpfiles() == files0, 'spooled body renamed by the handler',
        f'content-length: {st}; chunked: {st2}; temp files left {tmpfiles() - files0}')


def g_gc():
    """30 s of verified uploads; run against a server started with gcloop=1."""
    dur = float(os.environ.get('GC_SECS', '30'))
    stop = time.time() + dur
    counts = {'ok': 0, 'bad': 0, 'err': 0}
    lock = threading.Lock()
    samples = []

    def worker(seed):
        r = random.Random(seed)
        pool = os.urandom(3 << 20)
        s = conn(30)
        while time.time() < stop:
            n = r.choice([0, 1, 100, 8000, 9000, 20000, 70000, 300000, 1 << 20, 2 << 20])
            o = r.randrange(0, len(pool) - n + 1)
            body = pool[o:o + n]
            mode = r.choice(MODES)
            msg = head_cl(route('sha', mode), n) + body if r.random() < 0.7 or n == 0 else chunked_msg(route('sha', mode), body, [r.choice([100, 5000, 65536])])
            try:
                s.sendall(msg)
                res, closed = read_responses(s, 1, 30)
                good = bool(res) and res[-1] == (200, expect_sha(body))
                with lock:
                    counts['ok' if good else 'bad'] += 1
                    if not good and len(samples) < 5:
                        samples.append((mode, n, res[-1] if res else None))
                if closed or not res:
                    s.close()
                    s = conn(30)
            except OSError as e:
                with lock:
                    counts['err'] += 1
                s.close()
                s = conn(30)
        s.close()

    ts = [threading.Thread(target=worker, args=(i,)) for i in range(4)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    st = stats()
    out(counts['bad'] == 0 and counts['err'] == 0 and counts['ok'] > 100, f'{dur:.0f}s uploads under GC.gc() loop modes={MODES}',
        f"{counts['ok']} bodies sha256-verified, {counts['bad']} corrupt, {counts['err']} errors; {st} {samples}")


def g_big1g():
    """1 GiB streamed; RSS sampled by the caller through /stats is not possible mid-request, so ps is used."""
    pid = int(os.environ['SERVER_PID'])
    block = os.urandom(1 << 20)
    for mode in MODES:
        for kind in ('cl', 'chunked'):
            total = 1 << 30
            h = hashlib.sha256()
            rss = []
            done = threading.Event()

            def sample():
                while not done.is_set():
                    rss.append(int(subprocess.run(['ps', '-o', 'rss=', '-p', str(pid)], capture_output=True, text=True).stdout or 0))
                    time.sleep(0.1)
            rss0 = int(subprocess.run(['ps', '-o', 'rss=', '-p', str(pid)], capture_output=True, text=True).stdout)
            th = threading.Thread(target=sample)
            th.start()
            s = conn(300)
            t0 = time.time()
            if kind == 'cl':
                s.sendall(head_cl(route('sha', mode), total))
            else:
                s.sendall(f'POST {route("sha", mode)} HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n'.encode())
            for i in range(total >> 20):
                h.update(block)
                s.sendall(block if kind == 'cl' else b'100000\r\n' + block + b'\r\n')
            if kind == 'chunked':
                s.sendall(b'0\r\n\r\n')
            res, _ = read_responses(s, 1, 300)
            dt = time.time() - t0
            s.close()
            done.set()
            th.join()
            want = f'{total} {h.hexdigest()}'
            ok = bool(res) and res[-1] == (200, want)
            st = stats()
            out(ok and max(rss) - rss0 < 100000, f'1 GiB {kind} mode={mode}', f'sha256 {"match" if ok else "MISMATCH " + str(res)[:80]}; {total / dt / 1e6:.0f} MB/s incl. client hashing; server RSS start {rss0 // 1024} MB, peak {max(rss) // 1024} MB, end {rss[-1] // 1024} MB; pauses={st.get("pauses")} peak_queued={st.get("peak_queued")}')


for g in GROUPS:
    globals()['g_' + g]()
sys.exit(1 if fails else 0)
