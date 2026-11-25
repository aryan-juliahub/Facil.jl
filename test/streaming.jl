# Streamed responses: chunked framing on keep-alive connections, inline and task
# writers, back-pressure, HEAD, HTTP/1.0, failures and client disconnects.
module M6StreamingTests

using Facil, Test, Sockets
isdefined(Main, :M6Http) || Main.include(joinpath(@__DIR__, "m6_http.jl"))
using Main.M6Http
import Main.M6Http

const STREAM_PORTS = 3760:3769

const ST_STATE = (calls = Threads.Atomic{Int}(0), gone = Threads.Atomic{Int}(0), wrote = Threads.Atomic{Int}(0))

function stream_app(req)
    p = path(uri(req))
    parts = split(p, '/'; keepempty = false)
    if parts[1] == "chunks"
        n, size = parse(Int, parts[2]), parse(Int, parts[3])
        return stream(req; headers = [header.CONTENT_TYPE => "text/plain", "x-kind" => "chunks"]) do io
            Threads.atomic_add!(ST_STATE.calls, 1)
            for i in 1:n
                write(io, fill(UInt8('a' + (i - 1) % 26), size))
            end
        end
    elseif parts[1] == "paced"
        return stream(req) do io
            for i in 1:5
                write(io, "tick $i\n")
                Facil.sleep(0.05)
            end
        end
    elseif parts[1] == "big"
        n = parse(Int, parts[2])
        return stream(req; high_water = 256 * 1024) do io
            for i in 1:n
                v = Vector{UInt8}(undef, 1 << 20)
                fill!(v, UInt8(i % 251))
                write(io, v)
            end
        end
    elseif parts[1] == "variety"
        return stream(req) do io
            print(io, 42, ' ', 3.5, '\n')
            write(io, 0x41)
            write(io, SubString("xxhelloxx", 3, 7))
            write(io, view(UInt8[0x31, 0x32, 0x33, 0x34], 2:3))
            flush(io)
            write(io, "end")
        end
    elseif parts[1] == "fail"
        return stream(req) do io
            write(io, "partial")
            flush(io)
            error("boom")
        end
    elseif parts[1] == "forever"
        return stream(req) do io
            try
                while true
                    write(io, "x"^1000)
                    Threads.atomic_add!(ST_STATE.wrote, 1)
                    Facil.sleep(0.002)
                end
            catch e
                e isa Base.IOError && Threads.atomic_add!(ST_STATE.gone, 1)
                rethrow()
            end
        end
    elseif parts[1] == "status"
        return stream(req; status = StatusCodes.CREATED, headers = ["x-a" => "1"]) do io
            write(io, "made")
        end
    end
    Response(StatusCodes.OK, "plain " * p)
end

# Reads a chunked body of 1 MiB blocks, each filled with its index mod 251.
function read_blocks(s)
    got = 0
    ok = true
    while true
        n = parse(Int, readline(s); base = 16)
        n == 0 && break
        b = read(s, n)
        readline(s)
        for (k, x) in enumerate(b)
            x == UInt8(((got + k - 1) >> 20 + 1) % 251) || (ok = false; break)
        end
        got += n
    end
    readline(s)
    ok, got
end

expected_chunks(n, size) = reduce(vcat, [fill(UInt8('a' + (i - 1) % 26), size) for i in 1:n])

@testset "streaming" begin
    for (mode, inline) in (("inline", true), ("task", false))
        @testset "$mode" begin
            srv = serve!(stream_app, first(STREAM_PORTS) + (inline ? 0 : 1); inline)
            port = Facil.port(srv)
            try
                r = get1(port, "/chunks/10/1024")
                @test r.status == 200
                @test r["transfer-encoding"] == "chunked"
                @test r["content-type"] == "text/plain"
                @test r["x-kind"] == "chunks"
                @test !haskey(r, "content-length")
                @test r.body == expected_chunks(10, 1024)

                # keep-alive: a stream, a plain reply and another stream on one connection
                s, t = rawconn(port)
                send_raw(s, request("GET", "/chunks/3/100"))
                @test read_response(s).body == expected_chunks(3, 100)
                send_raw(s, request("GET", "/hello"))
                @test M6Http.text(read_response(s)) == "plain /hello"
                # pipelined: both answers, in order
                send_raw(s, request("GET", "/chunks/2/10000") * request("GET", "/after") * request("GET", "/chunks/1/5"))
                @test read_response(s).body == expected_chunks(2, 10000)
                @test M6Http.text(read_response(s)) == "plain /after"
                @test read_response(s).body == expected_chunks(1, 5)
                close(t); close(s)

                r = get1(port, "/variety")
                @test String(r.body) == "42 3.5\nAhello23end"

                r = get1(port, "/status")
                @test r.status == 201 && r["x-a"] == "1" && String(r.body) == "made"

                # HEAD: the head only, and the body function never runs
                before = ST_STATE.calls[]
                r = get1(port, "/chunks/4/10"; method = "HEAD")
                @test r.status == 200 && isempty(r.body)
                @test r["transfer-encoding"] == "chunked"
                @test ST_STATE.calls[] == before

                # HTTP/1.0: no chunked framing, the body ends with the connection
                r = get1(port, "/chunks/3/50"; version = "1.0")
                @test r.status == 200
                @test !haskey(r, "transfer-encoding")
                @test r["connection"] == "close"
                @test r.body == expected_chunks(3, 50)
                @test wait_until(() -> Facil.live_streams() == 0)
            finally
                close(srv); wait(srv)
            end
        end
    end

    @testset "task writers" begin
        srv = serve!(stream_app, STREAM_PORTS[3])
        port = Facil.port(srv)
        try
            # paced chunks reach the client one by one, before the body ends
            s, t = rawconn(port)
            send_raw(s, request("GET", "/paced"))
            _, hs = M6Http.read_head(s)
            @test hs["transfer-encoding"] == "chunked"
            t0 = time()
            first_line = readline(s)
            first_chunk = readline(s)
            t_first = time() - t0
            @test first_chunk == "tick 1"
            rest = String(readuntil(s, "0\r\n\r\n"))
            t_all = time() - t0
            @test occursin("tick 5", rest)
            @test t_first < t_all - 0.1
            close(t); close(s)

            # 32 MiB from a task through a 256 KiB high-water mark, read slowly at first
            s, t = rawconn(port; timeout = 60)
            send_raw(s, request("GET", "/big/32"))
            _, hs = M6Http.read_head(s)
            sleep(0.5)
            ok, got = read_blocks(s)
            @test ok
            @test got == 32 << 20
            close(t); close(s)
            @test wait_until(() -> Facil.pinned_bodies() == 0)

            # many concurrent streams
            results = Vector{Bool}(undef, 50)
            @sync for i in 1:50
                Threads.@spawn results[i] = get1(port, "/chunks/20/3000").body == expected_chunks(20, 3000)
            end
            @test all(results)
            @test wait_until(() -> Facil.live_streams() == 0)
        finally
            close(srv); wait(srv)
        end
    end

    @testset "failures and disconnects" begin
        for inline in (true, false)
            srv = serve!(stream_app, STREAM_PORTS[4 + inline]; inline)
            port = Facil.port(srv)
            try
                # a body function that throws: the connection closes mid-body
                s, t = rawconn(port)
                send_raw(s, request("GET", "/fail"))
                st, hs = M6Http.read_head(s)
                @test st == 200
                rest = read(s)
                @test occursin("partial", String(rest))
                @test !endswith(String(rest), "0\r\n\r\n")
                close(t); close(s)
                @test get1(port, "/ok").status == 200
            finally
                close(srv); wait(srv)
            end
        end
        srv = serve!(stream_app, STREAM_PORTS[6])
        port = Facil.port(srv)
        try
            g = ST_STATE.gone[]
            s, t = rawconn(port)
            send_raw(s, request("GET", "/forever"))
            M6Http.read_head(s)
            read(s, 5000)
            close(t); close(s)
            @test wait_until(() -> ST_STATE.gone[] == g + 1)
            @test wait_until(() -> Facil.live_streams() == 0)
            @test get1(port, "/ok").status == 200
        finally
            close(srv); wait(srv)
        end
    end

    @testset "arguments" begin
        @test_throws ArgumentError stream(io -> nothing; high_water = 0)
        @test_throws ArgumentError stream(io -> nothing; compress = :lz4)
        r = stream(io -> nothing; compress = :gz)
        @test r.body.compress === :gzip
        @test stream(io -> nothing; compress = nothing).body.compress === :none
    end
end

end
