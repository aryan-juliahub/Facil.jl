# HTTP server tests: real servers on ports 3600-3649, checked with curl and a Node client.

using Facil, Test
const F = Facil

const SPORTS = 3600:3649
const STAKEN = Set{Int}()

listening(p) = !isempty(readchomp(ignorestatus(`lsof -nP -t -iTCP:$p -sTCP:LISTEN`)))

function sport()
    for p in SPORTS
        (p in STAKEN || listening(p)) && continue
        push!(STAKEN, p)
        return p
    end
    error("no free port in $SPORTS")
end

const NODE = something(Sys.which("node"), "node")

const CLIENT_JS = raw"""
const net = require('net');
const [mode, port, ...rest] = process.argv.slice(2);
const PORT = +port;

// Minimal HTTP/1.1 response reader: calls onres({status, headers, body}) per response.
function reader(onres) {
  let buf = Buffer.alloc(0), need = -1, head = null;
  return (chunk) => {
    buf = buf.length ? Buffer.concat([buf, chunk]) : chunk;
    for (;;) {
      if (!head) {
        const i = buf.indexOf('\r\n\r\n');
        if (i < 0) return;
        const lines = buf.subarray(0, i).toString('latin1').split('\r\n');
        const status = +lines[0].split(' ')[1];
        const headers = {};
        for (const l of lines.slice(1)) { const k = l.indexOf(':'); headers[l.slice(0, k).trim().toLowerCase()] = l.slice(k + 1).trim(); }
        head = { status, headers };
        need = +(headers['content-length'] || 0);
        buf = buf.subarray(i + 4);
      }
      if (buf.length < need) return;
      const body = buf.subarray(0, need);
      buf = buf.subarray(need);
      const h = head; head = null;
      onres({ status: h.status, headers: h.headers, body });
    }
  };
}

const req = (path) => `GET ${path} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n`;

// /fresh/<n> bodies: 8-byte little-endian sequence number, then the low byte of it.
function verifyFresh(n, body) {
  if (body.length !== n) return false;
  const seq = Number(body.readBigUInt64LE(0) & 0xffffffffn);
  const fill = seq & 0xff;
  for (let i = 8; i < n; i++) if (body[i] !== fill) return false;
  return true;
}

if (mode === 'pipeline') {
  const n = +rest[0];
  const s = net.connect(PORT, '127.0.0.1');
  const got = [];
  s.on('data', reader((r) => { got.push(r.status + ':' + r.body.toString()); if (got.length === n) { console.log(JSON.stringify(got)); s.end(); } }));
  s.on('connect', () => { let all = ''; for (let i = 0; i < n; i++) all += req('/seq/' + i); s.write(all); });
  s.on('error', (e) => { console.log(JSON.stringify({ error: String(e) })); process.exit(1); });
} else if (mode === 'load') {
  // load <conns> <total> <sizes,comma> [tolerant]
  const conns = +rest[0], total = +rest[1], sizes = rest[2].split(',').map(Number), tolerant = rest[3] === 'tolerant';
  let sent = 0, ok = 0, bad = 0, errors = 0, done = 0;
  const finish = () => { if (++done === conns) console.log(JSON.stringify({ ok, bad, errors })); };
  for (let c = 0; c < conns; c++) {
    const s = net.connect(PORT, '127.0.0.1');
    let size = 0;
    const next = () => {
      if (sent >= total) { s.end(); return; }
      size = sizes[sent++ % sizes.length];
      s.write(req('/fresh/' + size));
    };
    s.on('connect', next);
    s.on('data', reader((r) => { (r.status === 200 && verifyFresh(size, r.body)) ? ok++ : bad++; next(); }));
    s.on('error', () => { errors++; });
    s.on('close', finish);
    if (tolerant) s.setTimeout(10000, () => s.destroy());
  }
} else if (mode === 'disconnect') {
  // disconnect <count> <concurrency> <path>
  const count = +rest[0], conc = +rest[1], path = rest[2];
  let started = 0, closed = 0, firstBytes = 0;
  const one = () => {
    if (started >= count) return;
    started++;
    const s = net.connect(PORT, '127.0.0.1');
    s.on('connect', () => s.write(req(path)));
    s.once('data', () => { firstBytes++; s.destroy(); });
    s.on('error', () => {});
    s.on('close', () => { closed++; if (closed === count) console.log(JSON.stringify({ closed, firstBytes })); else one(); });
  };
  for (let i = 0; i < conc; i++) one();
}
"""

const CLIENT = let p = joinpath(mktempdir(), "client.js")
    write(p, CLIENT_JS)
    p
end

node(args...) = chomp(read(`$NODE $CLIENT $(string.(args))`, String))
curl(args...) = read(ignorestatus(`curl -s --max-time 30 $(collect(args))`), String)
curl_status(args...) = parse(Int, read(ignorestatus(`curl -s -o /dev/null -w "%{http_code}" --max-time 30 $(collect(args))`), String))
url(p, path) = "http://127.0.0.1:$p$path"

function fresh(n::Int, seq::Int)
    v = Vector{UInt8}(undef, n)
    fill!(v, seq % UInt8)
    for k in 0:min(7, n - 1)
        v[k+1] = ((seq >>> (8k)) & 0xff) % UInt8
    end
    v
end
pattern(n) = UInt8[((i * 7 + (i >>> 10)) & 0xff) % UInt8 for i in 0:n-1]

const SEQ = Threads.Atomic{Int}(0)
const PATTERNS = Dict(n => pattern(n) for n in (1024, 65536, 1 << 20, 8 << 20))

function app(req)
    p = path(uri(req))
    if p == "/hello"
        "hello"
    elseif p == "/empty"
        Response(StatusCodes.NO_CONTENT)
    elseif p == "/json"
        Response(StatusCodes.OK, """{"a":1}"""; headers = [header.CONTENT_TYPE => "application/json"])
    elseif p == "/echo"
        Response(StatusCodes.OK, body(req); headers = ["x-echo" => something(get(headers(req), "x-echo", nothing), "none"),
                                                     header.CONTENT_TYPE => "application/octet-stream"])
    elseif p == "/headers"
        join(("$k=$v" for (k, v) in headers(req)), "\n")
    elseif p == "/info"
        string(method(req), " ", uri(req), " ", version(req), " ", something(query(uri(req)), "-"))
    elseif p == "/cookies"
        Response(StatusCodes.OK, "c"; headers = [header.SET_COOKIE => "a=1", header.SET_COOKIE => "b=2", "x-empty" => ""])
    elseif startswith(p, "/pattern/")
        Response(StatusCodes.OK, PATTERNS[parse(Int, p[10:end])])
    elseif startswith(p, "/fresh/")
        fresh(parse(Int, p[8:end]), Threads.atomic_add!(SEQ, 1) + 1) |> b -> Response(StatusCodes.OK, b)
    elseif startswith(p, "/freshstr/")
        Response(StatusCodes.OK, repeat("y", parse(Int, p[11:end])))
    elseif startswith(p, "/seq/")
        p[6:end]
    elseif p == "/error"
        error("handler failure")
    elseif p == "/bad"
        42
    else
        Response(StatusCodes.NOT_FOUND)
    end
end

function wait_until(f; timeout = 10.0)
    t = time()
    while !f()
        time() - t > timeout && return false
        sleep(0.01)
    end
    true
end

@testset "server" begin
    p = sport()
    srv = serve!(app, "127.0.0.1", p)
    @test srv isa Server
    @test isopen(srv)
    @test port(srv) == p
    @test srv.options.inline == (Threads.nthreads(:default) == 1)
    @test_throws ArgumentError serve!(app, "127.0.0.1", sport(); timeout = 0)
    @test_throws ArgumentError serve!(app, "127.0.0.1", sport(); reactors = F.fjl_reactor_threads() + 1)
    @test_throws SystemError serve!(app, "127.0.0.1", p)

    @testset "basics" begin
        @test curl(url(p, "/hello")) == "hello"
        head = curl("-i", url(p, "/hello"))
        @test occursin(r"(?i)content-type: ?text/plain; charset=utf-8", head)
        @test occursin(r"(?i)content-length: ?5\r\n", head)
        h = curl("-s", "-I", url(p, "/hello"))
        @test startswith(h, "HTTP/1.1 200")
        @test occursin(r"(?i)content-length: ?5\r\n", h)
        # HEAD then GET on one connection: the HEAD reply carries no body.
        two = curl("-i", "-I", url(p, "/hello"), "--next", "-i", url(p, "/seq/x"))
        @test endswith(two, "\r\n\r\nx")
        @test curl(url(p, "/json")) == """{"a":1}"""
        @test occursin(r"(?i)content-type: ?application/json", curl("-i", url(p, "/json")))
        @test curl_status(url(p, "/empty")) == 204
        @test curl_status(url(p, "/nope")) == 404
        @test curl("-i", url(p, "/nope")) |> s -> occursin(r"(?i)content-length: ?0", s)
        @test curl("-X", "POST", "-d", "payload", "-H", "x-echo: hi", url(p, "/echo")) == "payload"
        @test occursin(r"(?i)x-echo: ?hi\r\n", curl("-i", "-X", "POST", "-d", "p", "-H", "x-echo: hi", url(p, "/echo")))
        @test occursin(r"(?i)x-echo: ?none\r\n", curl("-i", "-X", "PUT", "--data-binary", "", url(p, "/echo")))
        @test curl(url(p, "/info?x=1&y=%20z")) == "GET /info?x=1&y=%20z HTTP/1.1 x=1&y=%20z"
        @test curl(url(p, "/info")) == "GET /info HTTP/1.1 -"
        @test curl("-X", "DELETE", url(p, "/info")) == "DELETE /info HTTP/1.1 -"
        @test curl("-X", "PURGE", url(p, "/info")) == "PURGE /info HTTP/1.1 -"
        @test curl("--http1.0", url(p, "/info")) == "GET /info HTTP/1.0 -"
    end

    @testset "headers" begin
        out = curl("-H", "Accept: text/html", "-H", "X-Custom: one", "-H", "x-custom: two",
                   "-H", "Cookie: a=b", "-H", "X-Weird_Name: w", url(p, "/headers"))
        lines = split(out, '\n')
        @test "accept=text/html" in lines
        @test "cookie=a=b" in lines
        @test "x-weird_name=w" in lines
        i = findfirst(==("x-custom=one"), lines)
        @test i !== nothing && lines[i+1] == "x-custom=two"
        @test any(startswith("host="), lines)
        r = curl("-i", url(p, "/cookies"))
        @test occursin(r"(?i)set-cookie: ?a=1\r\n", r)
        @test occursin(r"(?i)set-cookie: ?b=2\r\n", r)
        @test occursin(r"(?i)x-empty:", r)
    end

    @testset "errors" begin
        @test curl_status(url(p, "/error")) == 500
        @test curl_status(url(p, "/bad")) == 500
        @test curl(url(p, "/hello")) == "hello"
        @test curl_status("-H", "Bad Header: x", url(p, "/hello")) == 400
    end

    @testset "large bodies" begin
        dir = mktempdir()
        for n in sort!(collect(keys(PATTERNS)))
            f = joinpath(dir, "p$n")
            run(`curl -s --max-time 60 -o $f $(url(p, "/pattern/$n"))`)
            @test read(f) == PATTERNS[n]
            f2 = joinpath(dir, "e$n")
            write(joinpath(dir, "in$n"), PATTERNS[n])
            run(`curl -s --max-time 60 -o $f2 --data-binary @$(joinpath(dir, "in$n")) $(url(p, "/echo"))`)
            @test read(f2) == PATTERNS[n]
        end
        @test length(curl(url(p, "/freshstr/3000000"))) == 3_000_000
        @test wait_until(() -> F.pinned_bodies() == 0)
    end

    @testset "keep-alive and pipelining" begin
        v = curl(url(p, "/seq/a"), url(p, "/seq/b"), url(p, "/seq/c"))
        @test v == "abc"
        out = read(`sh -c "curl -s -v $(url(p, "/seq/a")) $(url(p, "/seq/b")) 2>&1"`, String)
        @test occursin(r"(?i)re-?using", out)
        got = node("pipeline", p, 64)
        @test got == "[" * join(("\"200:$i\"" for i in 0:63), ",") * "]"
    end

    @testset "two servers" begin
        p2 = sport()
        srv2 = serve!(req -> "second", p2)
        @test curl(url(p2, "/x")) == "second"
        @test curl(url(p, "/hello")) == "hello"
        close(srv2)
        wait(srv2)
        @test !isopen(srv2)
        @test curl_status(url(p2, "/x")) == 0
        @test curl(url(p, "/hello")) == "hello"
        srv3 = serve!(req -> "third", p2)
        @test curl(url(p2, "/x")) == "third"
        close(srv3)
        wait(srv3)
    end

    @testset "port 0" begin
        s0 = serve!(req -> "zero", "127.0.0.1", 0)
        @test port(s0) > 0
        @test curl(url(port(s0), "/")) == "zero"
        close(s0)
        wait(s0)
    end

    @testset "GC during 100k requests with large bodies" begin
        GC.gc()
        pr = run(pipeline(`$NODE $CLIENT load $p 32 100000 1024,16384,65536,131072,4096,200000`; stdout = (out = IOBuffer())); wait = false)
        n = 0
        while process_running(pr)
            junk = [Vector{UInt8}(undef, rand(1:300_000)) for _ in 1:8]
            GC.gc(rand(Bool))
            n += 1
            sleep(0.002)
        end
        wait(pr)
        r = chomp(String(take!(out)))
        @test r == """{"ok":100000,"bad":0,"errors":0}"""
        @test n > 10
        @test wait_until(() -> F.pinned_bodies() == 0)
    end

    @testset "1000 mid-download disconnects" begin
        r = node("disconnect", p, 1000, 50, "/fresh/8388608")
        @test r == "{\"closed\":1000,\"firstBytes\":1000}"
        @test wait_until(() -> F.pinned_bodies() == 0; timeout = 30)
        @test curl(url(p, "/hello")) == "hello"
        @test wait_until(() -> F.connections(srv) == 0; timeout = 30)
    end

    @testset "close under load" begin
        p3 = sport()
        s3 = serve!(app, p3)
        out = IOBuffer()
        pr = run(pipeline(`$NODE $CLIENT load $p3 64 100000000 1024,262144,4096 tolerant`; stdout = out); wait = false)
        sleep(1.0)
        @test F.connections(s3) > 0
        close(s3)
        @test !isopen(s3)
        @test timedwait(() -> (@atomic s3.state) == F.CLOSED, 30.0) === :ok
        wait(s3)
        wait(pr)
        r = chomp(String(take!(out)))
        @test occursin("\"bad\":0", r)
        @test F.connections(s3) == 0
        @test wait_until(() -> F.pinned_bodies() == 0)
        @test curl_status(url(p3, "/hello")) == 0
        @test curl(url(p, "/hello")) == "hello"
    end

    close(srv)
    wait(srv)
    @test !isopen(srv)
    @test wait_until(() -> isempty(F.LIVE); timeout = 10)
end
