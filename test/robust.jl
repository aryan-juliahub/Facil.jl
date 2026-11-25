# Limits, malformed requests, timeouts, slow clients, several servers, graceful
# close and SIGTERM. Ports 3720-3749. Node clients from test/patches/robust/tests.

using Facil, Test, Sockets
const F = Facil

const RPORTS = 3720:3749
const RTAKEN = Set{Int}()
rlistening(p) = !isempty(readchomp(ignorestatus(`lsof -nP -t -iTCP:$p -sTCP:LISTEN`)))
function rport()
    for p in RPORTS
        (p in RTAKEN || rlistening(p)) && continue
        push!(RTAKEN, p)
        return p
    end
    error("no free port in $RPORTS")
end

const NODE = something(Sys.which("node"), "node")
const RT = joinpath(@__DIR__, "patches", "robust", "tests")
rnode(script, args...) = readchomp(ignorestatus(`$NODE $(joinpath(RT, script)) $args`))
oklines(out) = [l for l in split(out, '\n') if startswith(l, "ok") || startswith(l, "FAIL")]

const SMALL = """{"id":1,"name":"alice"}"""

function rapp(req)
    p = path(uri(req))
    p == "/json" && return Response(StatusCodes.OK, SMALL; headers = [header.CONTENT_TYPE => "application/json"])
    p == "/hello" && return "hello"
    p == "/info" && return "headers $(length(headers(req)))"
    p == "/upload" && return string(sizeof(body(req)))
    p == "/big" && return Response(StatusCodes.OK, fill(UInt8('b'), 1 << 20))
    p == "/huge" && return Response(StatusCodes.OK, fill(UInt8('h'), 96 << 20))
    Response(StatusCodes.NOT_FOUND)
end

rss_mb() = parse(Int, strip(read(`ps -o rss= -p $(getpid())`, String))) ÷ 1024

function connect_refused(p)
    try
        close(Sockets.connect("127.0.0.1", p))
        false
    catch
        true
    end
end

# A keep-alive connection that made one request; `closed[]` turns true when the server closes it.
function idle_conn(p)
    s = Sockets.connect("127.0.0.1", p)
    write(s, "GET /hello HTTP/1.1\r\nHost: x\r\n\r\n")
    closed = Threads.Atomic{Bool}(false)
    @async try
        while !eof(s)
            readavailable(s)
        end
        closed[] = true
    catch
        closed[] = true
    end
    s, closed
end

# Sends `n` bytes of body over `secs` seconds; returns the task giving the reply text.
function slow_upload(p, n, secs; pieces = 10)
    @async begin
        s = Sockets.connect("127.0.0.1", p)
        try
            write(s, "POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: $n\r\n\r\n")
            for _ in 1:pieces
                sleep(secs / pieces)
                write(s, repeat("u", n ÷ pieces))
            end
            String(readavailable(s))
        catch e
            "error: $(sprint(showerror, e))"
        finally
            close(s)
        end
    end
end

@testset "robustness" begin
    @testset "errors: 431, 414, 413, 400 (1 MiB body limit)" begin
        p = rport()
        srv = serve!(rapp, "127.0.0.1", p; max_body_size = 1 << 20)
        out = rnode("errors.mjs", p)
        lines = oklines(out)
        @test length(lines) >= 12
        for l in lines
            @test startswith(l, "ok")
            startswith(l, "ok") || @info l
        end
        for (c, want) in (("cl-neg", ["400"]), ("cl-te", ["400"]), ("cl-huge", ["400", "413"]),
                          ("chunk-huge", ["400"]), ("negchunk", ["400"]))
            r = rnode("parser.mjs", p, c)
            m = match(r"statuses=\[(\d+)\] conn=closed \| server alive afterwards: true", r)
            @test m !== nothing && m[1] in want
            m === nothing && @info r
        end
        close(srv); wait(srv)
    end

    @testset "header timeout and slowloris (200 connections)" begin
        p = rport()
        srv = serve!(rapp, "127.0.0.1", p; header_timeout = 4)
        out = rnode("deadline.mjs", p, 4)
        for l in oklines(out)
            @test startswith(l, "ok")
            startswith(l, "ok") || @info l
        end
        r = rnode("client.js", "slowloris", p, 200, 9)
        @test occursin("\"stillOpen\":0", r)
        @test occursin("\"closedByServer\":200", r)
        @test occursin("\"HTTP/1.1 408 Request Timeout\":200", r)
        occursin("\"stillOpen\":0", r) || @info r
        @test readchomp(`curl -s http://127.0.0.1:$p/hello`) == "hello"
        close(srv); wait(srv)
    end

    @testset "slow readers: 200 x 8 pipelined 1 MB, RSS bounded" begin
        p = rport()
        srv = serve!(rapp, "127.0.0.1", p)
        GC.gc()
        r = rnode("client.js", "slowread", p, 200, 10, getpid(), 8)
        before = parse(Int, match(r"\"rssBeforeMB\":(\d+)", r)[1])
        peak = parse(Int, match(r"\"rssPeakMB\":(\d+)", r)[1])
        @test occursin("\"connected\":200", r)
        @test peak - before < 500
        peak - before < 500 || @info r
        @test readchomp(`curl -s http://127.0.0.1:$p/hello`) == "hello"
        close(srv); wait(srv)
        GC.gc()
    end

    @testset "max_pending_output drops a client that stopped reading" begin
        p = rport()
        srv = serve!(rapp, "127.0.0.1", p; max_pending_output = 8 << 20)
        socks = [Sockets.connect("127.0.0.1", p) for _ in 1:5]
        foreach(s -> write(s, "GET /huge HTTP/1.1\r\nHost: x\r\n\r\n"), socks)
        sleep(0.5)
        @test F.connections(srv) == 5
        @test timedwait(() -> F.connections(srv) == 0, 10; pollint = 0.1) == :ok
        @test timedwait(() -> F.pinned_bodies() == 0, 5) == :ok
        foreach(close, socks)
        close(srv); wait(srv)

        p = rport()
        srv = serve!(rapp, "127.0.0.1", p; max_pending_output = 0)
        s = Sockets.connect("127.0.0.1", p)
        write(s, "GET /huge HTTP/1.1\r\nHost: x\r\n\r\n")
        sleep(5)
        @test F.connections(srv) == 1
        close(s)
        close(srv); wait(srv)
    end

    @testset "idle timeout" begin
        p = rport()
        srv = serve!(rapp, "127.0.0.1", p; timeout = 3)
        for l in oklines(rnode("idle.mjs", p, 200, 3))
            @test startswith(l, "ok")
            startswith(l, "ok") || @info l
        end
        close(srv); wait(srv)
    end

    @testset "several servers" begin
        ps = [rport() for _ in 1:3]
        srvs = [serve!(rapp, "127.0.0.1", ps[1]; max_body_size = 1000),
                serve!(rapp, "127.0.0.1", ps[2]; before_body = h -> Reject(403)),
                serve!(rapp, "127.0.0.1", ps[3]; body_in_memory = 2000)]
        code(p, n) = readchomp(`curl -s -o /dev/null -w '%{http_code}' --data-binary $(repeat("a", n)) http://127.0.0.1:$p/upload`)
        @test [code(ps[1], 500), code(ps[1], 1500)] == ["200", "413"]
        @test [code(ps[2], 10), code(ps[2], 50_000)] == ["403", "403"]
        @test [code(ps[3], 1500), code(ps[3], 5000), code(ps[3], 50_000)] == ["200", "413", "413"]
        close(srvs[2]); wait(srvs[2])
        @test connect_refused(ps[2])
        @test code(ps[1], 10) == "200" && code(ps[3], 10) == "200"
        foreach(close, srvs); foreach(wait, srvs)
        @test all(connect_refused, ps)
        again = serve!(rapp, "127.0.0.1", ps[2])
        @test code(ps[2], 10) == "200"
        close(again); wait(again)
    end

    @testset "close(server; grace) lets open requests finish" begin
        p = rport()
        srv = serve!(rapp, "127.0.0.1", p)
        s, closed = idle_conn(p)
        up = slow_upload(p, 100_000, 2.0)
        sleep(0.5)
        t0 = time()
        close(srv; grace = 8)
        sleep(0.3)
        @test connect_refused(p)
        @test timedwait(() -> closed[], 6) == :ok
        @test endswith(fetch(up), "100000")
        wait(srv)
        @test time() - t0 < 7.5
        close(s)

        srv = serve!(rapp, "127.0.0.1", p)
        up = slow_upload(p, 100_000, 6.0)
        sleep(0.5)
        t0 = time()
        close(srv; grace = 1)
        wait(srv)
        @test time() - t0 < 3
        @test !endswith(fetch(up), "100000")
    end
end

@testset "SIGTERM drains servers started with serve (subprocess)" begin
    p, q = rport(), rport()
    script = """
    using Facil
    app(req) = path(uri(req)) == "/upload" ? string(sizeof(body(req))) : "hi"
    other = serve!(app, "127.0.0.1", $q)
    serve(app, "127.0.0.1", $p; shutdown_grace = 8, verbose = true)
    """
    err = Pipe()
    proc = run(pipeline(`$(Base.julia_cmd()) --project=$(Base.active_project()) --startup-file=no -e $script`; stderr = err); wait = false)
    close(err.in)
    errtxt = @async read(err, String)
    try
        @test timedwait(() -> !connect_refused(p) && !connect_refused(q), 120; pollint = 0.2) == :ok
        s, closed = idle_conn(p)
        up = slow_upload(p, 100_000, 2.0)
        up2 = slow_upload(q, 50_000, 2.0)
        sleep(0.5)
        t0 = time()
        kill(proc, Base.SIGTERM)
        @test timedwait(() -> connect_refused(p) && connect_refused(q), 3; pollint = 0.1) == :ok
        @test timedwait(() -> closed[], 6) == :ok
        @test endswith(fetch(up), "100000")
        @test endswith(fetch(up2), "50000")
        wait(proc)
        @test time() - t0 < 7
        @test proc.termsignal == Base.SIGTERM
        close(s)
    finally
        process_running(proc) && kill(proc, Base.SIGKILL)
    end
    txt = fetch(errtxt)
    @test occursin("listening on http://127.0.0.1:$p", txt)
    @test occursin("closing 2 server(s)", txt)
end
