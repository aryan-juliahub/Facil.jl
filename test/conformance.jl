# Status lines, bodyless statuses, the request line, serve keywords, the
# public_folder options, WebSocket shutdown on close and the signal drain.
module ConformanceTests

using Facil, Test, Sockets
isdefined(Main, :M6Http) || Main.include(joinpath(@__DIR__, "m6_http.jl"))
using Main.M6Http

# Sends `req` on a new connection and returns everything the server wrote
# until it closed or went quiet.
function exchange(port, req; quiet = 0.3)
    s = connect(ip"127.0.0.1", port)
    write(s, req)
    buf = UInt8[]
    last = Ref(time())
    reader = @async try
        while !eof(s)
            append!(buf, readavailable(s))
            last[] = time()
        end
    catch
    end
    while !istaskdone(reader) && time() - last[] < quiet
        sleep(0.02)
    end
    close(s)
    String(buf)
end
get_raw(port, target) = exchange(port, "GET $target HTTP/1.1\r\nHost: x\r\n\r\n")
status_line(r) = String(first(split(r, "\r\n")))
body_of(r) = String(last(split(r, "\r\n\r\n"; limit = 2)))
has_header(r, name) = occursin(Regex("\r\n" * name * ":", "i"), first(split(r, "\r\n\r\n"; limit = 2)))

function ws_connect(port)
    s = connect(ip"127.0.0.1", port)
    write(s, "GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" *
             "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n")
    head = String(readuntil(s, "\r\n\r\n"))
    startswith(head, "HTTP/1.1 101") || error("no upgrade: $head")
    s
end

# One unmasked server frame with a payload under 126 bytes: (opcode, payload).
function ws_frame(s)
    h = read(s, 2)
    length(h) == 2 || return (-1, UInt8[])
    (Int(h[1] & 0x0f), read(s, Int(h[2] & 0x7f)))
end

@testset "conformance" begin
    @testset "every status keeps its number" begin
        server = serve!(0) do req
            Response(StatusCode(parse(Int, path(uri(req))[2:end])), "b")
        end
        try
            s, timer = rawconn(port(server); timeout = 120)
            for code in 200:999
                send_raw(s, "GET /$code HTTP/1.1\r\nHost: x\r\n\r\n")
                line = readuntil(s, "\r\n")
                reason = something(canonical_reason(StatusCode(code)), "Unknown")
                line == "HTTP/1.1 $code $reason" || @test line == "HTTP/1.1 $code $reason"
                head = readuntil(s, "\r\n\r\n")
                m = match(r"content-length:(\d+)", head)
                m === nothing || read(s, parse(Int, m[1]))
            end
            close(timer)
            close(s)
            @test status_line(get_raw(port(server), "/418")) == "HTTP/1.1 418 I'm a teapot"
            @test status_line(get_raw(port(server), "/451")) == "HTTP/1.1 451 Unavailable For Legal Reasons"
            @test status_line(get_raw(port(server), "/299")) == "HTTP/1.1 299 Unknown"
            @test body_of(get_raw(port(server), "/418")) == "b"
            for code in 100:199
                s, timer = rawconn(port(server))
                send_raw(s, "GET /$code HTTP/1.1\r\nHost: x\r\n\r\n")
                reason = something(canonical_reason(StatusCode(code)), "Unknown")
                @test readuntil(s, "\r\n") == "HTTP/1.1 $code $reason"
                close(timer)
                close(s)
            end
        finally
            close(server)
        end
    end

    @testset "204 and 304 are sent without content" begin
        for compress in (false, true)
            server = serve!(0; compress) do req
                p = path(uri(req))
                p == "/204" && return Response(204, "x"^5000)
                p == "/304" && return Response(304, "x"^5000; headers = ["etag" => "\"v1\"", "cache-control" => "max-age=60"])
                Response(200, "after")
            end
            try
                s, timer = rawconn(port(server))
                send_raw(s, "GET /204 HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip\r\n\r\nGET /304 HTTP/1.1\r\nHost: x\r\n\r\nGET /x HTTP/1.1\r\nHost: x\r\n\r\n")
                h204 = readuntil(s, "\r\n\r\n")
                h304 = readuntil(s, "\r\n\r\n")
                @test startswith(h204, "HTTP/1.1 204 No Content")
                @test !occursin("content-length", h204)
                @test !occursin("content-type", h204)
                @test !occursin("content-encoding", h204)
                @test startswith(h304, "HTTP/1.1 304 Not Modified")
                @test !occursin("content-length", h304)
                @test occursin("etag:\"v1\"", h304)
                @test occursin("cache-control:max-age=60", h304)
                r = read_response(s)
                @test r.status == 200 && String(r.body) == "after"
                close(timer)
                close(s)
            finally
                close(server)
            end
        end
    end

    @testset "a request line with a space in the target is rejected" begin
        hits = Threads.Atomic{Int}(0)
        server = serve!(req -> (Threads.atomic_add!(hits, 1); "ok"), 0)
        try
            p = port(server)
            @test startswith(exchange(p, "GET /a b HTTP/1.1\r\nHost: x\r\n\r\n"), "HTTP/1.1 400 ")
            @test startswith(exchange(p, "GET /a?q=1 2 HTTP/1.1\r\nHost: x\r\n\r\n"), "HTTP/1.1 400 ")
            @test startswith(exchange(p, "GET  /a HTTP/1.1\r\nHost: x\r\n\r\n"), "HTTP/1.1 400 ")
            @test startswith(exchange(p, "GET /a HTTP/1.1 \r\nHost: x\r\n\r\n"), "HTTP/1.1 400 ")
            @test hits[] == 0
            @test startswith(get_raw(p, "/a%20b?q=1+2"), "HTTP/1.1 200 ")
            @test startswith(exchange(p, "GET http://x/a HTTP/1.1\r\nHost: x\r\n\r\n"), "HTTP/1.1 200 ")
            @test hits[] == 2
        finally
            close(server)
        end
    end

    @testset "unknown serve keywords" begin
        e = try
            serve!(identity, 0; timout = 3)
        catch err
            err
        end
        @test e isa ArgumentError
        @test occursin("no keyword `timout`", e.msg)
        @test occursin("did you mean `timeout`?", e.msg)
        @test occursin("shutdown_grace", e.msg) && occursin("public_folder", e.msg)
        e = try
            serve(identity, 0; frobnicate = 1)
        catch err
            err
        end
        @test e isa ArgumentError
        @test occursin("no keyword `frobnicate`.", e.msg)
        @test !occursin("did you mean", e.msg)
        @test_throws ArgumentError serve!(identity, 0; dotfiles = :deny)
        @test_throws ArgumentError serve!(identity, 0; public_folder = mktempdir(), dotfiles = :hide)
        @test_throws ArgumentError serve!(identity, 0; public_folder = mktempdir(), symlinks = :never)
    end

    @testset "public_folder: NUL, traversal, dotfiles, symlinks" begin
        dir = mktempdir()
        outside = mktempdir()
        write(joinpath(dir, "a.txt"), "AAA")
        write(joinpath(dir, "a.txt.secret"), "S")
        write(joinpath(dir, ".env"), "KEY=1")
        mkpath(joinpath(dir, ".git"))
        write(joinpath(dir, ".git", "config"), "cfg")
        mkpath(joinpath(dir, "sub"))
        write(joinpath(dir, "sub", "b.txt"), "BBB")
        write(joinpath(outside, "secret.txt"), "outside")
        symlink(joinpath(outside, "secret.txt"), joinpath(dir, "out.txt"))
        symlink(outside, joinpath(dir, "outdir"))
        symlink(joinpath(dir, "a.txt"), joinpath(dir, "in.txt"))
        handler(req) = Response(200, "handler")
        served(p, t) = (r = get_raw(p, t); (parse(Int, split(status_line(r), ' ')[2]), body_of(r)))

        server = serve!(handler, 0; public_folder = dir, dotfiles = :serve)
        try
            p = port(server)
            @test served(p, "/a.txt") == (200, "AAA")
            @test served(p, "/a.txt%00.secret")[1] == 400
            @test served(p, "/a.txt%00")[1] == 400
            @test served(p, "/%00")[1] == 400
            @test served(p, "/sub/b.txt") == (200, "BBB")
            for t in ("/../a.txt", "/sub/../../etc/passwd", "/%2e%2e/%2e%2e/etc/passwd", "/..%2f..%2fetc%2fpasswd",
                      "/sub%2f..%2f..%2fetc/passwd", "/sub//b.txt", "/sub/..")
                @test served(p, t) == (200, "handler") || t
            end
            # dotfiles = :serve serves dotfiles; by default symbolic links are followed.
            @test served(p, "/.env") == (200, "KEY=1")
            @test served(p, "/.git/config") == (200, "cfg")
            @test served(p, "/out.txt") == (200, "outside")
            @test served(p, "/outdir/secret.txt") == (200, "outside")
            @test served(p, "/in.txt") == (200, "AAA")
        finally
            close(server)
        end

        server = serve!(handler, 0; public_folder = dir, dotfiles = :deny, symlinks = :inside)
        try
            p = port(server)
            @test served(p, "/a.txt") == (200, "AAA")
            @test served(p, "/sub/b.txt") == (200, "BBB")
            @test served(p, "/in.txt") == (200, "AAA")
            @test served(p, "/.env") == (200, "handler")
            @test served(p, "/.git/config") == (200, "handler")
            @test served(p, "/%2eenv") == (200, "handler")
            @test served(p, "/out.txt") == (200, "handler")
            @test served(p, "/outdir/secret.txt") == (200, "handler")
            @test served(p, "/a.txt%00")[1] == 400
        finally
            close(server)
        end

        # A folder reached through a symbolic link still serves its own files.
        link = joinpath(mktempdir(), "site")
        symlink(dir, link)
        server = serve!(handler, 0; public_folder = link, symlinks = :inside)
        try
            @test served(port(server), "/a.txt") == (200, "AAA")
            @test served(port(server), "/out.txt") == (200, "handler")
        finally
            close(server)
        end
    end

    @testset "close(server) shuts its WebSockets down" begin
        for grace in (0, 3)
            events = Channel{Symbol}(Inf)
            server = serve!(0) do req
                websocket(req; on_shutdown = ws -> (send(ws, "bye"); put!(events, :shutdown)),
                          on_close = ws -> put!(events, :close))
            end
            other = serve!(req -> websocket(req; on_shutdown = ws -> put!(events, :other)), 0)
            try
                c = ws_connect(port(server))
                o = ws_connect(port(other))
                @test wait_until(() -> Facil.connections(server) == 1)
                close(server; grace)
                @test ws_frame(c) == (1, Vector{UInt8}("bye"))
                op, payload = ws_frame(c)
                @test op == 8
                @test payload == [0x03, 0xe9]
                @test try
                    eof(c)
                catch
                    true
                end
                wait(server)
                @test take!(events) === :shutdown
                @test take!(events) === :close
                @test Facil.connections(other) == 1
                @test !isready(events)
                close(c)
                close(o)
            finally
                close(server)
                close(other)
            end
        end
    end

    @testset "Facil.Timer prints its state" begin
        t = Facil.Timer(_ -> nothing, 60)
        @test occursin(r"^Facil\.Timer\(.*open", sprint(show, t))
        close(t)
        @test occursin("closed", sprint(show, t))
    end

    @testset "the error log limit is per call site" begin
        Facil.log_error_reset!()
        raise_a() = error("a")
        raise_b() = error("b")
        trace(f) = try
            f()
        catch e
            (e, catch_backtrace())
        end
        logged(f) = (x = trace(f); Facil.log_error_key(x...))
        @test logged(raise_a) == logged(raise_a)
        @test logged(raise_a) != logged(raise_b)
        @test logged(raise_a) != logged(() -> throw(ArgumentError("a")))
    end
end

function signal_script(port)
    """
    using Facil
    serve("127.0.0.1", $port; shutdown_grace = 6, verbose = true) do req
        p = path(uri(req))
        p == "/base" && Base.sleep(1.0)
        p == "/facil" && Facil.sleep(1.0)
        p == "/proc" && run(`sleep 1`)
        p == "/ws" && return websocket(req; on_shutdown = ws -> send(ws, "bye"))
        "finished " * p
    end
    """
end

function get_raw_slow(port, target)
    s = connect(ip"127.0.0.1", port)
    write(s, "GET $target HTTP/1.1\r\nHost: x\r\n\r\n")
    r = try
        String(read(s))
    catch
        ""
    end
    close(s)
    r
end

# Handlers waiting on Julia's event loop finish when it runs off thread 1.
const DRAINS_IO = isdefined(Base.Experimental, :make_io_thread)

@testset "a signal drains handlers that wait on I/O (subprocess)" begin
    for (threads, sig) in ((4, Base.SIGTERM), (4, Base.SIGINT), (1, Base.SIGTERM))
        port = Int(@ccall Facil.LIBFJL.fjl_http_free_port("127.0.0.1"::Cstring)::Cint)
        dir = mktempdir()
        file = joinpath(dir, "server.jl")
        write(file, signal_script(port))
        err = Pipe()
        proc = run(pipeline(`$(Base.julia_cmd()) -t $threads --project=$(Base.active_project()) --startup-file=no $file`; stderr = err); wait = false)
        close(err.in)
        errtxt = @async read(err, String)
        try
            @test wait_until(timeout = 120) do
                try
                    close(connect(ip"127.0.0.1", port))
                    true
                catch
                    false
                end
            end
            c = ws_connect(port)
            replies = [@async(get_raw_slow(port, t)) for t in ("/base", "/facil", "/proc")]
            sleep(0.4)
            t0 = time()
            kill(proc, sig)
            if DRAINS_IO
                @test [body_of(fetch(r)) for r in replies] == ["finished /base", "finished /facil", "finished /proc"]
                @test ws_frame(c) == (1, Vector{UInt8}("bye"))
                @test ws_frame(c) == (8, [0x03, 0xe9])
            end
            wait(proc)
            @test time() - t0 < (DRAINS_IO ? 5 : 10)
            @test proc.termsignal == sig
            close(c)
        finally
            process_running(proc) && kill(proc, Base.SIGKILL)
        end
        @test occursin("closing 1 server(s)", fetch(errtxt))
    end
end


end
