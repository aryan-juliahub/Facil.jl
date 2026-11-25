# Task handlers, paused connections and several reactor threads. Ports 3650-3679.
# Included by runtests.jl; scenarios that need their own thread or reactor
# counts run as `julia -t 4 async.jl <scenario> <port> [reactors]`.

module AsyncTests

using Facil, Test
const F = Facil

const PORTS = 3650:3679
const TAKEN = Set{Int}()
listening(p) = !isempty(readchomp(ignorestatus(`lsof -nP -t -iTCP:$p -sTCP:LISTEN`)))

function free_port()
    for p in PORTS
        (p in TAKEN || listening(p)) && continue
        push!(TAKEN, p)
        return p
    end
    error("no free port in $PORTS")
end

const NODE = something(Sys.which("node"), "node")

const CLIENT_JS = raw"""
const net = require('net');
const [mode, port, ...rest] = process.argv.slice(2);
const PORT = +port;
function reader(onres) {
  let buf = Buffer.alloc(0), need = -1, head = null;
  return (chunk) => {
    buf = buf.length ? Buffer.concat([buf, chunk]) : chunk;
    for (;;) {
      if (!head) {
        const i = buf.indexOf('\r\n\r\n');
        if (i < 0) return;
        const lines = buf.subarray(0, i).toString('latin1').split('\r\n');
        const headers = {};
        for (const l of lines.slice(1)) { const k = l.indexOf(':'); headers[l.slice(0, k).trim().toLowerCase()] = l.slice(k + 1).trim(); }
        head = { status: +lines[0].split(' ')[1] };
        need = +(headers['content-length'] || 0);
        buf = buf.subarray(i + 4);
      }
      if (buf.length < need) return;
      const body = buf.subarray(0, need);
      buf = buf.subarray(need);
      const h = head; head = null;
      onres({ status: h.status, body });
    }
  };
}
const req = (path) => `GET ${path} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n`;
// /rep/<k>/<n>: n bytes, byte j = (k + j) % 251
function verify(k, n, body) {
  if (body.length !== n) return false;
  for (let j = 0; j < n; j += (n > 4096 ? 97 : 1)) if (body[j] !== (k + j) % 251) return false;
  return n === 0 || body[n - 1] === (k + n - 1) % 251;
}
if (mode === 'pload') {
  // pload <conns> <rounds> <depth> <sizes,comma> <prefix>: pipelined rounds, replies checked in order
  const conns = +rest[0], rounds = +rest[1], depth = +rest[2], sizes = rest[3].split(',').map(Number), prefix = rest[4];
  let ok = 0, bad = 0, errors = 0, done = 0;
  const finish = () => { if (++done === conns) console.log(JSON.stringify({ ok, bad, errors })); };
  for (let c = 0; c < conns; c++) {
    const s = net.connect(PORT, '127.0.0.1');
    let round = 0, want = [];
    const next = () => {
      if (round++ >= rounds) { s.end(); return; }
      let all = '';
      want = [];
      for (let i = 0; i < depth; i++) {
        const k = c * 7919 + round * 131 + i, n = sizes[(c + round + i) % sizes.length];
        want.push([k, n]);
        all += req(`${prefix}/${k}/${n}`);
      }
      s.write(all);
    };
    s.on('connect', next);
    s.on('data', reader((r) => {
      const [k, n] = want.shift();
      (r.status === 200 && verify(k, n, r.body)) ? ok++ : bad++;
      if (want.length === 0) next();
    }));
    s.on('error', () => { errors++; });
    s.on('close', finish);
  }
} else if (mode === 'abort') {
  // abort <count> <concurrency> <path> <ms>: send a request, close the socket after ms
  const count = +rest[0], conc = +rest[1], path = rest[2], ms = +rest[3];
  let started = 0, closed = 0, answered = 0;
  const one = () => {
    if (started >= count) return;
    started++;
    const s = net.connect(PORT, '127.0.0.1');
    s.on('connect', () => { s.write(req(path)); setTimeout(() => s.destroy(), ms); });
    s.on('data', () => { answered++; });
    s.on('error', () => {});
    s.on('close', () => { if (++closed === count) console.log(JSON.stringify({ closed, answered })); else one(); });
  };
  for (let i = 0; i < conc; i++) one();
}
"""

const CLIENT = let p = joinpath(mktempdir(), "async_client.js")
    write(p, CLIENT_JS)
    p
end
node(args...) = chomp(read(`$NODE $CLIENT $(string.(args))`, String))
curl(args...) = read(ignorestatus(`curl -s --max-time 30 $(collect(args))`), String)
curl_status(args...) = parse(Int, read(ignorestatus(`curl -s -o /dev/null -w "%{http_code}" --max-time 30 $(collect(args))`), String))
url(p, path) = "http://127.0.0.1:$p$path"

function wait_until(f; timeout = 10.0)
    t = time()
    while !f()
        time() - t > timeout && return false
        sleep(0.01)
    end
    true
end

rep(k, n) = UInt8[(k + j) % 251 for j in 0:n-1]

handler_version() = "v1"
const ON_REACTOR = Threads.Atomic{Int}(0)
const RUNNING = Threads.Atomic{Int}(0)
const PEAK = Threads.Atomic{Int}(0)
const SPAWN_DELAYS = Int[]
const SPAWN_LOCK = Threads.SpinLock()

function app(req)
    p = path(uri(req))
    F.fjl_on_reactor() && Threads.atomic_add!(ON_REACTOR, 1)
    if p == "/hello"
        "hello"
    elseif startswith(p, "/rep/") || startswith(p, "/jrep/")
        _, _, k, n = split(p, '/')
        startswith(p, "/j") && F.sleep(rand() * 0.002)
        Response(StatusCodes.OK, rep(parse(Int, k), parse(Int, n)))
    elseif startswith(p, "/block/")
        n = Threads.atomic_add!(RUNNING, 1) + 1
        Threads.atomic_max!(PEAK, n)
        Base.sleep(parse(Float64, p[8:end]))
        Threads.atomic_sub!(RUNNING, 1)
        "blocked"
    elseif startswith(p, "/fsleep/")
        F.sleep(parse(Float64, p[9:end]))
        Response(StatusCodes.OK, rep(1, 70_000))
    elseif p == "/error"
        error("handler failure")
    elseif p == "/bad"
        42
    elseif p == "/where"
        string(F.fjl_on_reactor())
    elseif startswith(p, "/spawnrep/")
        t0 = time_ns()
        Threads.@spawn (d = Int(time_ns() - t0); lock(SPAWN_LOCK); push!(SPAWN_DELAYS, d); unlock(SPAWN_LOCK))
        while time_ns() - t0 < 300_000
        end
        _, _, k, n = split(p, '/')
        Response(StatusCodes.OK, rep(parse(Int, k), parse(Int, n)))
    elseif p == "/child"
        fetch(@async (Base.sleep(0.01); "child"))
    elseif p == "/static"
        acc = zeros(Int, Threads.nthreads())
        Threads.@threads :static for i in 1:Threads.nthreads()
            acc[i] = i
        end
        string(sum(acc))
    elseif p == "/version"
        handler_version()
    else
        Response(StatusCodes.NOT_FOUND)
    end
end

no_leaks() = wait_until(() -> F.paused_requests() == 0 && all(isempty, F.RESULTS) && F.pinned_bodies() == 0; timeout = 30)

"Task handlers with one reactor (needs Julia threads)."
function scenario_tasks(p)
    @testset "task handlers ($(Threads.nthreads()) threads)" begin
        srv = serve!(app, p; timeout = 2)
        @test !srv.options.inline
        @test curl(url(p, "/hello")) == "hello"
        @test curl(url(p, "/where")) == "false"
        @test curl_status(url(p, "/error")) == 500
        @test curl_status(url(p, "/bad")) == 500
        @test curl_status(url(p, "/nope")) == 404
        @test curl(url(p, "/hello")) == "hello"
        @test ON_REACTOR[] == 0

        # Idle workers wait in C; tasks that need their threads still run.
        @test wait_until(() -> F.fjl_work_idle() >= 1)
        @test all(==("child"), [curl(url(p, "/child")) for _ in 1:20])
        n = Threads.nthreads()
        @test all(==(string(n * (n + 1) ÷ 2)), [curl(url(p, "/static")) for _ in 1:5])
        @test curl(url(p, "/version")) == "v1"
        @eval handler_version() = "v2"
        @test curl(url(p, "/version")) == "v2"
        @test timedwait(() -> (Base.sleep(0.05); true), 5.0) === :ok

        # 40 handlers that block for 0.3 s run side by side.
        t = @elapsed got = fetch.([@async curl(url(p, "/block/0.3")) for _ in 1:40])
        @test all(==("blocked"), got)
        @test t < 3
        @test PEAK[] >= 2

        # Tasks a busy handler spawns still start while every worker is busy.
        @test curl(url(p, "/spawnrep/1/1")) == String(rep(1, 1))
        Base.sleep(0.2)
        lock(() -> empty!(SPAWN_DELAYS), SPAWN_LOCK)
        r = node("pload", p, 12, 150, 1, "0,1,700", "/spawnrep")
        @test r == """{"ok":1800,"bad":0,"errors":0}"""
        @test wait_until(() -> length(SPAWN_DELAYS) == 1800)
        d = sort!(lock(() -> copy(SPAWN_DELAYS), SPAWN_LOCK))
        println("spawned-task start delay under load: p50 ", d[900] ÷ 1000, " µs, p99 ", d[1782] ÷ 1000, " µs, max ", d[end] ÷ 1000, " µs")
        @test d[1782] < 50_000_000

        # Slower than the 2 s idle timeout: the paused connection is kept alive.
        @test curl(url(p, "/block/4.5")) == "blocked"

        r = node("pload", p, 16, 40, 16, "0,1,700,20000,70000", "/jrep")
        @test r == """{"ok":10240,"bad":0,"errors":0}"""

        # Clients that leave while their handler runs.
        d0 = F.DROPPED[]
        r = node("abort", p, 1000, 100, "/fsleep/0.05", 5)
        @test r == """{"closed":1000,"answered":0}"""
        @test no_leaks()
        @test wait_until(() -> F.connections(srv) == 0; timeout = 30)
        println("1000 aborted: dropped=", F.DROPPED[] - d0, " ", F.fjl_stats())
        @test curl(url(p, "/hello")) == "hello"

        # Closing the server while handlers are paused.
        tasks = [Threads.@spawn curl_status(url(p, "/fsleep/1.0")) for _ in 1:20]
        @test wait_until(() -> F.paused_requests() == 20; timeout = 10)
        close(srv)
        @test timedwait(() -> !isopen(srv) && (@atomic srv.state) == F.CLOSED, 10.0) === :ok
        wait(srv)
        @test all(t -> fetch(t) in (0, 200), tasks)
        @test no_leaks()
    end
end

"Inline and task handlers on several reactor threads under forced collections."
function scenario_reactors(p, p2, n)
    @testset "$n reactors, inline and task handlers" begin
        si = serve!(app, p; reactors = n, inline = true)
        st = serve!(app, p2; reactors = n)
        @test F.fjl_reactor_threads() == n
        @test !st.options.inline
        stop = Threads.Atomic{Bool}(false)
        gcs = Threads.Atomic{Int}(0)
        gc_task = Threads.@spawn while !stop[]
            junk = [Vector{UInt8}(undef, rand(1:200_000)) for _ in 1:8]
            GC.gc(rand(Bool))
            Threads.atomic_add!(gcs, 1)
            Base.sleep(0.005)
        end
        for (s, prefix) in ((si, "/rep"), (st, "/rep"), (st, "/jrep"))
            q = port(s)
            t = @elapsed r = node("pload", q, 64, 100, 8, "0,1,333,4096,65536,200000", prefix)
            @test r == """{"ok":51200,"bad":0,"errors":0}"""
            println("$n reactors $(s.options.inline ? "inline" : "task") $prefix: 51200 requests in $(round(t, digits = 2)) s, $(gcs[]) collections so far")
        end
        stop[] = true
        wait(gc_task)
        @test gcs[] > 10
        @test no_leaks()
        @test ON_REACTOR[] > 0
        close(si); close(st)
        wait(si); wait(st)
    end
end

"One Julia thread: inline = false still runs handlers inline."
function scenario_one_thread(p)
    @testset "one Julia thread" begin
        srv = serve!(app, p; verbose = false)
        @test srv.options.inline
        @test curl(url(p, "/where")) == "true"
        t = @elapsed @test length(curl(url(p, "/fsleep/0.02"))) == 70_000
        @test t >= 0.02
        @test curl(url(p, "/rep/3/10")) == String(rep(3, 10))
        close(srv)
        wait(srv)
    end
end

subprocess(threads, args...) = success(run(ignorestatus(
    `$(Base.julia_cmd()) --project=$(Base.active_project()) --startup-file=no -t $threads $(@__FILE__) $(string.(args))`)))

function main()
    @testset "async" begin
        if Threads.nthreads(:default) == 1
            scenario_one_thread(free_port())
            @test subprocess(4, "tasks", free_port())
        else
            scenario_tasks(free_port())
        end
        for n in (4, 8)
            @test subprocess(4, "reactors", free_port(), free_port(), n)
        end
    end
end

end # module

if abspath(PROGRAM_FILE) == @__FILE__
    args = ARGS[2:end]
    port = parse(Int, args[1])
    if ARGS[1] == "tasks"
        AsyncTests.scenario_tasks(port)
    elseif ARGS[1] == "reactors"
        AsyncTests.scenario_reactors(port, parse(Int, args[2]), parse(Int, args[3]))
    end
    exit(0)
else
    AsyncTests.main()
end
