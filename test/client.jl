# The client of a request: client_address, client_certificate, isconnected and
# on_disconnect; the date header of streamed responses. Ports 4120-4149.

module ClientTests

using Facil, Test, Sockets

const PORTS = 4120:4149
const NEXT = Ref(0)
in_use(p) = !isempty(readchomp(ignorestatus(`lsof -nP -t -iTCP:$p`)))
# Ports are handed out in turn, so a port comes back only after the others.
function free_port()
    for _ in PORTS
        p = PORTS[NEXT[] % length(PORTS) + 1]
        NEXT[] += 1
        in_use(p) || return p
    end
    error("no free port in $PORTS")
end

const CERTS = joinpath(@__DIR__, "certs")
cert(name) = joinpath(CERTS, name * "_cert.pem")
key(name) = joinpath(CERTS, name * "_key.pem")
curl(args...) = read(ignorestatus(`curl -s --max-time 10 $args`), String)

function withserver(f, handler, host = "127.0.0.1"; kw...)
    p = free_port()
    srv = serve!(handler, host, p; kw...)
    try
        f(p, srv)
    finally
        close(srv); wait(srv)
    end
end

function wait_until(f; timeout = 10)
    t0 = time()
    while !f()
        time() - t0 > timeout && return false
        sleep(0.02)
    end
    true
end

# Closes `s` with a reset instead of a FIN.
function reset_close(s::TCPSocket)
    fd = Base._fd(s)
    sol, linger = Sys.isapple() ? (0xffff, 0x0080) : (1, 13)
    ccall(:setsockopt, Cint, (Cint, Cint, Cint, Ptr{Cvoid}, Cuint), fd, sol, linger, Ref((Int32(1), Int32(0))), 8)
    close(s)
end

function read_all(s; timeout = 10)
    t = Timer(_ -> close(s), timeout)
    out = try
        read(s)
    catch
        UInt8[]
    end
    close(t)
    String(out)
end

@testset "client" begin
    @testset "client_address" begin
        addr(req) = (c = client_address(req); "$(c.ip) $(c.port)")
        for inline in (true, false)
            withserver(addr; inline) do p, _
                lp = free_port()
                @test curl("--local-port", lp, "http://127.0.0.1:$p/") == "127.0.0.1 $lp"
            end
            withserver(addr; inline, tls = TLSConfig(cert("rsa"), key("rsa"))) do p, _
                lp = free_port()
                @test curl("-k", "--local-port", lp, "https://127.0.0.1:$p/") == "127.0.0.1 $lp"
            end
            v6 = try
                close(listen(ip"::1", 0)); true
            catch
                false
            end
            v6 && withserver(addr, "::1"; inline) do p, _
                lp = free_port()
                @test curl("-g", "--local-port", lp, "http://[::1]:$p/") == "::1 $lp"
            end
        end

        # captured with the request: still there after the connection is gone
        kept = Channel{Any}(4)
        withserver(req -> (put!(kept, req); "ok")) do p, _
            lp = free_port()
            @test curl("--local-port", lp, "http://127.0.0.1:$p/") == "ok"
            req = take!(kept)
            sleep(0.2)
            @test client_address(req) == (ip = "127.0.0.1", port = lp)
            @test client_certificate(req) === nothing
        end
        # an inline handler asks while it runs; without asking it is gone afterwards
        withserver(req -> (path(uri(req)) == "/ask" && client_address(req); put!(kept, req); "ok"); inline = true) do p, _
            lp = free_port()
            curl("--local-port", lp, "http://127.0.0.1:$p/ask")
            @test client_address(take!(kept)) == (ip = "127.0.0.1", port = lp)
            curl("http://127.0.0.1:$p/no")
            @test client_address(take!(kept)) === nothing
        end

        # stream, SSE and WebSocket handlers
        for inline in (true, false)
            withserver(req -> (c = client_address(req); stream(io -> write(io, string(c.port)), req)); inline) do p, _
                lp = free_port()
                @test curl("--local-port", lp, "http://127.0.0.1:$p/") == string(lp)
            end
            withserver(req -> sse(io -> write_event(io, string(client_address(req).port)), req); inline) do p, _
                lp = free_port()
                @test strip(curl("--local-port", lp, "-H", "Accept: text/event-stream", "http://127.0.0.1:$p/")) == "data: $lp"
            end
            seen = Channel{Any}(1)
            withserver(req -> (put!(seen, client_address(req)); websocket(req; on_open = ws -> close(ws))); inline) do p, _
                s = connect(ip"127.0.0.1", p)
                _, lp = getsockname(s)
                write(s, "GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" *
                         "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n")
                @test startswith(readline(s), "HTTP/1.1 101")
                @test take!(seen) == (ip = "127.0.0.1", port = Int(lp))
                close(s)
            end
        end

        # a request built by hand has no connection
        req = Request(Methods.GET, "/")
        @test client_address(req) === nothing
        @test client_certificate(req) === nothing
        @test isconnected(req)
        @test on_disconnect(() -> error("never"), req) === nothing
    end

    @testset "client_certificate" begin
        pem = read(cert("client"), String)
        show_cert(req) = something(client_certificate(req), "none")
        for inline in (true, false)
            withserver(show_cert; inline, tls = TLSConfig(cert("rsa"), key("rsa"); client_ca = cert("ca"))) do p, _
                @test curl("-k", "--cert", cert("client"), "--key", key("client"), "https://127.0.0.1:$p/") == pem
                @test curl("-k", "https://127.0.0.1:$p/") == "none"
            end
            withserver(show_cert; inline, tls = TLSConfig(cert("rsa"), key("rsa"))) do p, _
                @test curl("-k", "--cert", cert("client"), "--key", key("client"), "https://127.0.0.1:$p/") == "none"
            end
            withserver(show_cert; inline) do p, _
                @test curl("http://127.0.0.1:$p/") == "none"
            end
        end
    end

    @testset "isconnected and on_disconnect" begin
        # a client that gives up: on_disconnect fires soon after, isconnected turns false
        for tls in (nothing, TLSConfig(cert("rsa"), key("rsa")))
            fired = Threads.Atomic{Float64}(0.0)
            states = Channel{Vector{Bool}}(1)
            slow = function (req)
                on_disconnect(() -> (fired[] = time()), req)
                seen = Bool[]
                t0 = time()
                while time() - t0 < 4
                    push!(seen, isconnected(req))
                    sleep(0.05)
                end
                put!(states, seen)
                "late"
            end
            withserver(slow; tls) do p, _
                url = tls === nothing ? "http://127.0.0.1:$p/" : "https://127.0.0.1:$p/"
                run(ignorestatus(`curl -s -k --max-time 1 $url`))
                gone_at = time()
                @test wait_until(() -> fired[] > 0; timeout = 3)
                @test fired[] - gone_at < 1.5
                seen = take!(states)
                @test first(seen) && !last(seen)
                @test issorted(seen; rev = true)
            end
        end

        # a half-close (HTTP/1.1 and 1.0) is not a disconnect: the reply still arrives
        for version in ("1.1", "1.0")
            log = Channel{Tuple{Bool,Bool}}(1)
            watcher = function (req)
                fired = Threads.Atomic{Bool}(false)
                on_disconnect(() -> (fired[] = true), req)
                t0 = time()
                ok = true
                while time() - t0 < 1.5
                    ok &= isconnected(req)
                    sleep(0.05)
                end
                put!(log, (ok, fired[]))
                "body"
            end
            withserver(watcher) do p, _
                s = connect(ip"127.0.0.1", p)
                write(s, "GET / HTTP/$version\r\nHost: x\r\n\r\n")
                closewrite(s)
                out = read_all(s)
                @test take!(log) == (true, false)
                @test endswith(out, "\r\n\r\nbody")
                @test occursin("HTTP/1.1 200 OK", out)
                # the probe that tells a half-close from a close is an interim reply
                @test startswith(out, version == "1.1" ? "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200" : "HTTP/1.1 200")
            end
        end

        # a reset counts at once, even for HTTP/1.0; a callback added later runs at once
        log = Channel{Bool}(1)
        late = Threads.Atomic{Bool}(false)
        until_reset = function (req)
            wait_until(() -> !isconnected(req); timeout = 5)
            on_disconnect(() -> (late[] = true), req)
            put!(log, isconnected(req))
            "x"
        end
        withserver(until_reset) do p, _
            s = connect(ip"127.0.0.1", p)
            write(s, "GET / HTTP/1.0\r\nHost: x\r\n\r\n")
            sleep(0.3)
            reset_close(s)
            @test take!(log) == false
            @test wait_until(() -> late[]; timeout = 3)
        end

        # a handler that returns first: its callback never runs, the state is final
        calls = Threads.Atomic{Int}(0)
        kept = Channel{Any}(1)
        withserver(req -> (on_disconnect(() -> Threads.atomic_add!(calls, 1), req); isconnected(req); put!(kept, req); "quick")) do p, _
            @test curl("http://127.0.0.1:$p/") == "quick"
            req = take!(kept)
            sleep(1)
            @test calls[] == 0
            @test isconnected(req)
            on_disconnect(() -> Threads.atomic_add!(calls, 1), req)
            sleep(0.3)
            @test calls[] == 0
        end

        # closing the server counts as a disconnect
        fired = Threads.Atomic{Bool}(false)
        started = Base.Event()
        p = free_port()
        srv = serve!(p) do req
            on_disconnect(() -> (fired[] = true), req)
            notify(started)
            wait_until(() -> fired[]; timeout = 5)
            "done"
        end
        task = @async curl("http://127.0.0.1:$p/")
        wait(started)
        close(srv)
        @test wait_until(() -> fired[]; timeout = 3)
        wait(srv); wait(task)

        # a streamed request body cut short
        fired = Threads.Atomic{Bool}(false)
        reader = function (req)
            on_disconnect(() -> (fired[] = true), req)
            try
                read(body_stream(req))
            catch
            end
            "x"
        end
        withserver(reader; before_body = head -> Stream()) do p, _
            s = connect(ip"127.0.0.1", p)
            write(s, "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 1000\r\n\r\n0123456789")
            sleep(0.3)
            close(s)
            @test wait_until(() -> fired[]; timeout = 3)
        end

        # inline handlers: always connected, callbacks never run
        calls = Threads.Atomic{Int}(0)
        withserver(req -> (on_disconnect(() -> Threads.atomic_add!(calls, 1), req); string(isconnected(req))); inline = true) do p, _
            @test curl("http://127.0.0.1:$p/") == "true"
            sleep(0.5)
            @test calls[] == 0
        end
    end

    @testset "streamed responses carry a date" begin
        for inline in (true, false)
            withserver(req -> stream(io -> write(io, "x"), req); inline) do p, _
                @test occursin(r"\r\ndate:[A-Z][a-z]{2}, \d{2} [A-Z][a-z]{2} \d{4} \d{2}:\d{2}:\d{2} GMT\r\n"i,
                               curl("-i", "http://127.0.0.1:$p/"))
            end
            withserver(req -> stream(io -> write(io, "x"), req; headers = ["date" => "mine"]); inline) do p, _
                @test occursin("\r\ndate:mine\r\n", curl("-i", "http://127.0.0.1:$p/"))
            end
            withserver(req -> sse(io -> write_event(io, "x"), req); inline) do p, _
                @test occursin(r"\r\ndate:[A-Z][a-z]{2}, \d{2} "i, curl("-i", "-H", "Accept: text/event-stream", "http://127.0.0.1:$p/"))
            end
        end
    end
end

end
