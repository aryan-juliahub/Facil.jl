# Clients that finish sending at once: write a request and close, or shut down
# the write side and read the reply. Ports 3830-3849. TLS client in
# test/tls/halfclose.js.

module HalfCloseTests

using Facil, Test, Sockets
const F = Facil

const PORTS = 3830:3849
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
const TLS_CLIENT = joinpath(@__DIR__, "tls", "halfclose.js")
const CERTS = joinpath(@__DIR__, "certs")
const N = 200
# `julia halfclose.jl reactors <n>` runs the plain-HTTP cases on n reactor threads.
const REACTORS = length(ARGS) == 2 && ARGS[1] == "reactors" ? parse(Int, ARGS[2]) : 0
options() = REACTORS > 0 ? (; reactors = REACTORS) : (;)

const HANDLED = Threads.Atomic{Int}(0)
const BODY_BYTES = Threads.Atomic{Int}(0)
const BIG = repeat("0123456789abcdef", 256 * 1024)

function app(req)
    Threads.atomic_add!(HANDLED, 1)
    Threads.atomic_add!(BODY_BYTES, sizeof(body(req)))
    p = path(uri(req))
    p == "/big" && return Response(StatusCodes.OK, BIG)
    p == "/slow" && (F.sleep(1.0); return "slow")
    p == "/stream" && return stream(req) do io
        for i in 1:20
            write(io, "chunk $i\n")
            flush(io)
            F.sleep(0.02)
        end
    end
    "ok " * p
end

const GET = "GET /a HTTP/1.1\r\nHost: x\r\n\r\n"
const POST = "POST /p HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello"
const PAIR = "GET /one HTTP/1.1\r\nHost: x\r\n\r\nGET /two HTTP/1.1\r\nHost: x\r\n\r\n"

function settle(want; timeout = 5)
    t0 = time()
    while HANDLED[] < want && time() - t0 < timeout
        sleep(0.01)
    end
    HANDLED[]
end

# Writes and closes at once, `n` times; returns the requests handled.
function fire(port, payload, n; expect = n, timeout = 5)
    HANDLED[] = 0
    BODY_BYTES[] = 0
    for _ in 1:n
        s = connect("127.0.0.1", port)
        write(s, payload)
        close(s)
    end
    settle(expect; timeout)
end

# Writes, shuts down the write side and reads to the end of the connection.
# Gives "" when the server has not closed the connection within `limit` seconds.
function half(port, payload; limit = 10)
    s = connect("127.0.0.1", port)
    late = Ref(false)
    watchdog = Timer(_ -> (late[] = true; close(s)), limit)
    try
        write(s, payload)
        closewrite(s)
        out = read(s, String)
        return late[] ? "" : out
    catch
        return ""
    finally
        close(watchdog)
        close(s)
    end
end

# Three requests on one connection; returns the replies read.
function keepalive(port)
    s = connect("127.0.0.1", port)
    n = 0
    for _ in 1:3
        write(s, GET)
        n += occursin("200 OK", readline(s))
        readuntil(s, "ok /a")
    end
    close(s)
    n
end

replies(s) = length(collect(eachmatch(r"HTTP/1\.1 200 OK", s)))

cpu_seconds() = ccall(:clock, Clong, ()) / (Sys.iswindows() ? 1000 : 1_000_000)

function plain(inline)
    kind = inline ? "inline" : "task"
    p = free_port()
    srv = serve!(app, "127.0.0.1", p; inline, options()...)
    try
        keepalive(p)
        @testset "write then close, $kind handler" begin
            @test fire(p, GET, N) == N
            @test fire(p, POST, N) == N
            @test BODY_BYTES[] == 5N
            # the reset that the first reply provokes may come before the second request starts
            pairs = fire(p, PAIR, N; expect = 2N, timeout = 1)
            @test N <= pairs <= 2N
            REACTORS == 0 && inline && @test pairs == 2N
        end
        @testset "write then shut down the write side, $kind handler" begin
            got = [half(p, GET) for _ in 1:N]
            @test count(endswith("ok /a"), got) == N
            got = [half(p, POST) for _ in 1:N]
            @test count(endswith("ok /p"), got) == N
            got = [half(p, PAIR) for _ in 1:N]
            @test count(s -> replies(s) == 2 && endswith(s, "ok /two"), got) == N
            got = [half(p, "GET /big HTTP/1.1\r\nHost: x\r\n\r\n") for _ in 1:10]
            @test count(s -> endswith(s, BIG) && replies(s) == 1, got) == 10
            if !inline
                got = half(p, "GET /stream HTTP/1.1\r\nHost: x\r\n\r\n")
                @test occursin("chunk 20\n", got) && endswith(got, "0\r\n\r\n")
            end
        end
        inline || @testset "a half-closed connection does not spin" begin
            c0 = cpu_seconds()
            out = half(p, "GET /slow HTTP/1.1\r\nHost: x\r\n\r\n")
            used = cpu_seconds() - c0
            @test endswith(out, "slow")
            @test used < 0.5
        end
        @testset "the server stays usable, $kind handler" begin
            @test endswith(half(p, GET), "ok /a")
            @test keepalive(p) == 3
        end
    finally
        close(srv)
    end
end

function over_tls(inline)
    kind = inline ? "inline" : "task"
    p = free_port()
    cfg = TLSConfig(joinpath(CERTS, "rsa_cert.pem"), joinpath(CERTS, "rsa_key.pem"))
    srv = serve!(app, "127.0.0.1", p; tls = cfg, inline)
    try
        @testset "TLS, $kind handler" begin
            HANDLED[] = 0
            @test readchomp(`$NODE $TLS_CLIENT $p destroy 100 /a`) == "100"
            @test settle(100) == 100
            HANDLED[] = 0
            @test readchomp(`$NODE $TLS_CLIENT $p end 100 /a`) == "100 $(100 * sizeof("ok /a"))"
            @test HANDLED[] == 100
            @test readchomp(`$NODE $TLS_CLIENT $p end 5 /big`) == "5 $(5 * sizeof(BIG))"
        end
    finally
        close(srv)
    end
end

function ws_frame(opcode, payload)
    key = UInt8[1, 2, 3, 4]
    data = Vector{UInt8}(codeunits(payload))
    vcat(UInt8[0x80 | opcode, 0x80 | length(data)], key, [data[i] ⊻ key[(i - 1) % 4 + 1] for i in eachindex(data)])
end

function websockets()
    p = free_port()
    messages = Threads.Atomic{Int}(0)
    closed = Threads.Atomic{Int}(0)
    srv = serve!("127.0.0.1", p; options()...) do req
        websocket(req; on_message = (ws, msg) -> Threads.atomic_add!(messages, 1),
                  on_close = ws -> Threads.atomic_add!(closed, 1))
    end
    try
        @testset "WebSocket: frames sent just before the close are delivered" begin
            for _ in 1:100
                s = connect("127.0.0.1", p)
                write(s, "GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" *
                         "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n")
                readuntil(s, "\r\n\r\n")
                write(s, vcat(ws_frame(0x1, "last words"), ws_frame(0x8, "\x03\xe8")))
                close(s)
            end
            t0 = time()
            while (messages[] < 100 || closed[] < 100) && time() - t0 < 10
                sleep(0.01)
            end
            @test messages[] == 100
            @test closed[] == 100
        end
    finally
        close(srv)
    end
end

subprocess(threads, args...) = success(run(ignorestatus(
    `$(Base.julia_cmd()) --project=$(Base.active_project()) --startup-file=no -t $threads $(@__FILE__) $(string.(args))`)))

if REACTORS > 0
    @testset "Clients that finish sending at once, $REACTORS reactors" begin
        plain(true)
        plain(false)
        websockets()
    end
else
    @testset "Clients that finish sending at once" begin
        plain(true)
        plain(false)
        over_tls(true)
        over_tls(false)
        websockets()
        for n in (4, 8)
            @test subprocess(4, "reactors", n)
        end
    end
end

end
