# WebSocket tests against a raw client written here. Ports 3800-3829.

module WebSocketTests

using Facil, Test, Sockets
const F = Facil

const PORTS = 3800:3829
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

# ---- a minimal client ----

mutable struct Client
    sock::TCPSocket
    status::Int
    headers::Dict{String,String}
end

function connect_ws(port, path = "/ws"; extensions = nothing, protocol = nothing, upgrade = true)
    s = connect("127.0.0.1", port)
    req = "GET $path HTTP/1.1\r\nHost: 127.0.0.1\r\n"
    upgrade && (req *= "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n")
    extensions === nothing || (req *= "Sec-WebSocket-Extensions: $extensions\r\n")
    protocol === nothing || (req *= "Sec-WebSocket-Protocol: $protocol\r\n")
    write(s, req * "\r\n")
    status = parse(Int, split(readline(s))[2])
    hs = Dict{String,String}()
    while true
        l = readline(s)
        isempty(l) && break
        k, v = split(l, ':'; limit = 2)
        hs[lowercase(strip(k))] = strip(v)
    end
    Client(s, status, hs)
end

function frame(opcode, payload::AbstractVector{UInt8}; fin = true, rsv1 = false, mask = true)
    io = IOBuffer()
    write(io, UInt8((fin ? 0x80 : 0) | (rsv1 ? 0x40 : 0) | opcode))
    n = length(payload)
    m = mask ? 0x80 : 0x00
    if n < 126
        write(io, UInt8(m | n))
    elseif n < 65536
        write(io, UInt8(m | 126), hton(UInt16(n)))
    else
        write(io, UInt8(m | 127), hton(UInt64(n)))
    end
    if mask
        key = rand(UInt8, 4)
        write(io, key)
        write(io, UInt8[payload[i] ⊻ key[(i-1)%4+1] for i in 1:n])
    else
        write(io, payload)
    end
    take!(io)
end

send_frame(c::Client, opcode, payload; kw...) = write(c.sock, frame(opcode, Vector{UInt8}(payload); kw...))
send_text(c::Client, s::AbstractString) = send_frame(c, 0x1, codeunits(s))
send_bin(c::Client, b::Vector{UInt8}) = send_frame(c, 0x2, b)

function read_frame(c::Client)
    s = c.sock
    b1, b2 = read(s, UInt8), read(s, UInt8)
    n = Int(b2 & 0x7f)
    n == 126 && (n = Int(ntoh(read(s, UInt16))))
    n == 127 && (n = Int(ntoh(read(s, UInt64))))
    b2 & 0x80 != 0 && error("server frames must not be masked")
    (opcode = b1 & 0x0f, fin = b1 & 0x80 != 0, rsv1 = b1 & 0x40 != 0, payload = read(s, n))
end

# Reads one whole message, answering nothing; returns (opcode, payload).
function read_message(c::Client)
    f = read_frame(c)
    op, data, rsv1 = f.opcode, f.payload, f.rsv1
    while !f.fin
        f = read_frame(c)
        append!(data, f.payload)
    end
    (opcode = op, payload = data, rsv1 = rsv1)
end

with_timeout(f, secs = 10) = (t = Threads.@spawn f(); timedwait(() -> istaskdone(t), secs) == :ok ? fetch(t) : error("timed out"))
close_payload(code, reason = "") = vcat(reinterpret(UInt8, [hton(UInt16(code))]), Vector{UInt8}(codeunits(reason)))
close_code(p) = length(p) >= 2 ? Int(p[1]) << 8 | p[2] : 0

# Reads until EOF and tells whether the server closed cleanly (no reset).
function clean_eof(c::Client)
    try
        while !eof(c.sock)
            read(c.sock, UInt8)
        end
        true
    catch e
        e isa Base.IOError || rethrow()
        false
    end
end

waitfor(f, secs = 5) = timedwait(f, secs; pollint = 0.01) == :ok

# ---- zlib raw inflate, for the permessage-deflate check ----

mutable struct ZStream
    next_in::Ptr{UInt8}; avail_in::Cuint; total_in::Culong
    next_out::Ptr{UInt8}; avail_out::Cuint; total_out::Culong
    msg::Ptr{UInt8}; state::Ptr{Cvoid}
    zalloc::Ptr{Cvoid}; zfree::Ptr{Cvoid}; opaque::Ptr{Cvoid}
    data_type::Cint; adler::Culong; reserved::Culong
    ZStream() = new(C_NULL, 0, 0, C_NULL, 0, 0, C_NULL, C_NULL, C_NULL, C_NULL, C_NULL, 0, 0, 0)
end
const LIBZ = Sys.isapple() ? "libz" : "libz.so.1"

function inflate_raw(data::Vector{UInt8})
    z = ZStream()
    ccall((:inflateInit2_, LIBZ), Cint, (Ref{ZStream}, Cint, Cstring, Cint), z, -15, "1.2.11", sizeof(ZStream)) == 0 || error("inflateInit2")
    input = vcat(data, UInt8[0x00, 0x00, 0xff, 0xff])
    out = Vector{UInt8}(undef, 1 << 22)
    GC.@preserve input out begin
        z.next_in, z.avail_in = pointer(input), length(input)
        z.next_out, z.avail_out = pointer(out), length(out)
        r = ccall((:inflate, LIBZ), Cint, (Ref{ZStream}, Cint), z, 2)
        n = length(out) - z.avail_out
    end
    ccall((:inflateEnd, LIBZ), Cint, (Ref{ZStream},), z)
    r in (0, 1, -5) || error("inflate returned $r")
    resize!(out, n)
end

# Compresses like a client: raw DEFLATE, sync flush, trailing 00 00 ff ff removed.
function deflate_sync(data::Vector{UInt8})
    z = ZStream()
    ccall((:deflateInit2_, LIBZ), Cint, (Ref{ZStream}, Cint, Cint, Cint, Cint, Cint, Cstring, Cint),
          z, 6, 8, -15, 8, 0, "1.2.11", sizeof(ZStream)) == 0 || error("deflateInit2")
    out = Vector{UInt8}(undef, length(data) + 1024)
    GC.@preserve data out begin
        z.next_in, z.avail_in = pointer(data), length(data)
        z.next_out, z.avail_out = pointer(out), length(out)
        ccall((:deflate, LIBZ), Cint, (Ref{ZStream}, Cint), z, 2) == 0 || error("deflate")
        n = length(out) - z.avail_out
    end
    ccall((:deflateEnd, LIBZ), Cint, (Ref{ZStream},), z)
    @assert out[n-3:n] == UInt8[0x00, 0x00, 0xff, 0xff]
    resize!(out, n - 4)
end

# ---- server under test ----

const EVENTS = Channel{Any}(Inf)
const SOCKETS = Dict{String,F.WebSocket}()
const SOCK_LOCK = ReentrantLock()

function handler(req)
    p = path(uri(req))
    q = something(query(uri(req)), "")
    if p == "/ws"
        return websocket(req;
            on_open = ws -> (put!(EVENTS, (:open, ws)); q == "" || lock(() -> (SOCKETS[q] = ws), SOCK_LOCK)),
            on_message = (ws, msg) -> begin
                if msg isa String && startswith(msg, "close:")
                    _, code, reason = split(msg, ':'; limit = 3)
                    close(ws; code = parse(Int, code), reason)
                elseif msg isa String && startswith(msg, "sub:")
                    subscribe(ws, msg[5:end])
                    send(ws, "subscribed")
                elseif msg isa String && startswith(msg, "unsub:")
                    unsubscribe(ws, msg[7:end])
                    send(ws, "unsubscribed")
                else
                    send(ws, msg)
                end
            end,
            on_close = ws -> put!(EVENTS, (:close, ws)),
            max_message_size = 4 * 1024 * 1024)
    elseif p == "/small"
        return websocket(req; on_message = (ws, msg) -> send(ws, msg), max_message_size = 1000)
    elseif p == "/noutf8"
        return websocket(req; on_message = (ws, msg) -> send(ws, msg), utf8_check = false)
    elseif p == "/deflate"
        return websocket(req; on_message = (ws, msg) -> send(ws, msg), deflate = true)
    elseif p == "/spawn"
        return websocket(req; spawn = true, on_message = (ws, msg) -> (msg == "slow" && sleep(0.05); send(ws, msg)))
    elseif p == "/proto"
        return websocket(req; subprotocol = "chat", on_open = ws -> send(ws, "hi"))
    elseif p == "/throws"
        return websocket(req; on_message = (ws, msg) -> msg == "boom" ? error("boom") : send(ws, msg))
    end
    Response(StatusCodes.NOT_FOUND)
end

function drain_events()
    while isready(EVENTS)
        take!(EVENTS)
    end
end

@testset "WebSockets" begin
    port = free_port()
    srv = serve!(handler, "127.0.0.1", port; inline = true)
    try
        @testset "is_upgrade and plain requests" begin
            c = connect_ws(port, "/nothing")
            @test c.status == 404
            close(c.sock)
            c = connect_ws(port, "/ws"; upgrade = false)
            @test c.status == 400
            close(c.sock)
        end

        @testset "echo, text and binary, all length encodings" begin
            drain_events()
            c = connect_ws(port)
            @test c.status == 101
            @test haskey(c.headers, "sec-websocket-accept")
            @test !haskey(c.headers, "sec-websocket-extensions")
            ev = with_timeout(() -> take!(EVENTS))
            @test ev[1] == :open && isopen(ev[2])
            with_timeout() do
                send_text(c, "hello")
                m = read_message(c)
                @test m.opcode == 0x1 && String(m.payload) == "hello"
                send_text(c, "")
                @test read_message(c).payload == UInt8[]
                for n in (1, 125, 126, 65535, 65536, 300_000, 2_000_000)
                    b = rand(UInt8, n)
                    send_bin(c, b)
                    m = read_message(c)
                    @test m.opcode == 0x2
                    @test m.payload == b
                end
                s = "héllo wörld ✓"^1000
                send_text(c, s)
                @test String(read_message(c).payload) == s
                # a fragmented message arrives whole
                send_frame(c, 0x1, codeunits("frag"); fin = false)
                send_frame(c, 0x0, codeunits("ment"); fin = true)
                @test String(read_message(c).payload) == "fragment"
                # ping is answered with pong, between messages
                send_frame(c, 0x9, codeunits("p1"))
                f = read_frame(c)
                @test f.opcode == 0xA && String(f.payload) == "p1"
            end
            # client-initiated close: the same code comes back, then a clean EOF
            with_timeout() do
                send_frame(c, 0x8, close_payload(1000, "bye"))
                f = read_frame(c)
                @test f.opcode == 0x8
                @test close_code(f.payload) == 1000
                @test clean_eof(c)
            end
            ev = with_timeout(() -> take!(EVENTS))
            @test ev[1] == :close && !isopen(ev[2])
            @test send(ev[2], "late") == false
            close(c.sock)
        end

        @testset "server close with code and reason" begin
            c = connect_ws(port)
            with_timeout() do
                send_text(c, "close:4001:going away now")
                f = read_frame(c)
                @test f.opcode == 0x8
                @test close_code(f.payload) == 4001
                @test String(f.payload[3:end]) == "going away now"
                send_frame(c, 0x8, close_payload(4001))
                @test clean_eof(c)
            end
            close(c.sock)
        end

        @testset "send from other threads; closed sockets drop messages" begin
            drain_events()
            c = connect_ws(port, "/ws?pusher")
            ws = with_timeout(() -> take!(EVENTS))[2]
            n = 2000
            tasks = [Threads.@spawn begin
                         for i in 1:n
                             send(ws, string(k, ":", i)) || error("send failed")
                         end
                     end for k in 1:4]
            got = Dict(k => 0 for k in 1:4)
            with_timeout(30) do
                for _ in 1:4n
                    k, i = parse.(Int, split(String(read_message(c).payload), ':'))
                    @test i == got[k] + 1
                    got[k] = i
                end
            end
            foreach(wait, tasks)
            @test all(==(n), values(got))
            close(c.sock)
            @test waitfor(() -> !isopen(ws))
            @test send(ws, "after close") == false
            @test send(ws, UInt8[1, 2, 3]) == false
            close(ws)  # no-op
            ev = with_timeout(() -> take!(EVENTS))
            @test ev[1] == :close
        end

        @testset "limits: message size and UTF-8" begin
            c = connect_ws(port, "/small")
            with_timeout() do
                send_bin(c, rand(UInt8, 900))
                @test length(read_message(c).payload) == 900
                send_bin(c, rand(UInt8, 1001))
                f = read_frame(c)
                @test f.opcode == 0x8 && close_code(f.payload) == 1009
            end
            close(c.sock)
            c = connect_ws(port, "/ws")
            with_timeout() do
                send_frame(c, 0x1, UInt8[0xff, 0xfe])
                f = read_frame(c)
                @test f.opcode == 0x8 && close_code(f.payload) == 1007
            end
            close(c.sock)
            c = connect_ws(port, "/noutf8")
            with_timeout() do
                send_frame(c, 0x1, UInt8[0xff, 0xfe])
                m = read_message(c)
                @test m.opcode == 0x1 && m.payload == UInt8[0xff, 0xfe]
            end
            close(c.sock)
        end

        @testset "subprotocol, callback errors" begin
            c = connect_ws(port, "/proto"; protocol = "chat, superchat")
            @test c.headers["sec-websocket-protocol"] == "chat"
            @test with_timeout(() -> String(read_message(c).payload)) == "hi"
            close(c.sock)
            c = connect_ws(port, "/throws")
            with_timeout() do
                send_text(c, "boom")
                send_text(c, "still here")
                @test String(read_message(c).payload) == "still here"
            end
            close(c.sock)
        end

        @testset "spawn = true keeps order" begin
            c = connect_ws(port, "/spawn")
            with_timeout() do
                send_text(c, "slow")
                for i in 1:200
                    send_text(c, string(i))
                end
                @test String(read_message(c).payload) == "slow"
                @test [String(read_message(c).payload) for _ in 1:200] == string.(1:200)
                big = rand(UInt8, 200_000)
                for _ in 1:20
                    send_bin(c, big)
                end
                @test all(read_message(c).payload == big for _ in 1:20)
            end
            close(c.sock)
        end

        @testset "permessage-deflate" begin
            c = connect_ws(port, "/deflate"; extensions = "permessage-deflate; client_max_window_bits")
            @test occursin("permessage-deflate", get(c.headers, "sec-websocket-extensions", ""))
            s = repeat("compress me please ", 500)
            with_timeout() do
                send_text(c, s)
                m = read_message(c)
                @test m.rsv1
                @test length(m.payload) < sizeof(s) ÷ 10
                @test String(inflate_raw(m.payload)) == s
                send_text(c, "tiny")
                m = read_message(c)
                @test !m.rsv1 && String(m.payload) == "tiny"
                # compressed by the client, text and binary, small and large
                for msg in (Vector{UInt8}(codeunits(s)), rand(UInt8, 100), repeat(UInt8[1, 2, 3, 4], 200_000))
                    send_frame(c, 0x2, deflate_sync(msg); rsv1 = true)
                    m = read_message(c)
                    @test (m.rsv1 ? inflate_raw(m.payload) : m.payload) == msg
                end
            end
            close(c.sock)
            for codec in (:zlib, :zlibng)
                F.websocket_compressor!(codec)
                c = connect_ws(port, "/deflate"; extensions = "permessage-deflate")
                with_timeout() do
                    send_frame(c, 0x1, deflate_sync(Vector{UInt8}(codeunits(s))); rsv1 = true)
                    m = read_message(c)
                    @test m.rsv1 && String(inflate_raw(m.payload)) == s
                end
                close(c.sock)
            end
            # routes without deflate decline it, even once it is on
            c = connect_ws(port, "/ws"; extensions = "permessage-deflate")
            @test c.status == 101
            @test !haskey(c.headers, "sec-websocket-extensions")
            close(c.sock)
        end

        @testset "broadcast through subscribe(ws, channel)" begin
            clients = [connect_ws(port) for _ in 1:20]
            with_timeout() do
                for c in clients
                    send_text(c, "sub:room")
                    @test String(read_message(c).payload) == "subscribed"
                end
            end
            for i in 1:100
                publish("room", "msg $i")
            end
            publish("room", UInt8[0xff, 0x00])
            with_timeout(20) do
                for c in clients
                    @test [String(read_message(c).payload) for _ in 1:100] == ["msg $i" for i in 1:100]
                    m = read_message(c)
                    @test m.opcode == 0x2 && m.payload == UInt8[0xff, 0x00]
                end
            end
            with_timeout() do
                send_text(clients[1], "unsub:room")
                @test String(read_message(clients[1]).payload) == "unsubscribed"
            end
            publish("room", "after")
            with_timeout() do
                @test String(read_message(clients[2]).payload) == "after"
                send_text(clients[1], "ping")
                @test String(read_message(clients[1]).payload) == "ping"
            end
            foreach(c -> close(c.sock), clients)
        end

        @testset "upgrade from a task handler" begin
            p2 = free_port()
            s2 = serve!(handler, "127.0.0.1", p2; inline = false)
            try
                drain_events()
                c = connect_ws(p2)
                @test c.status == 101
                ws = with_timeout(() -> take!(EVENTS))[2]
                with_timeout() do
                    for i in 1:3
                        sleep(0.3)
                        send_text(c, "from task $i")
                        @test String(read_message(c).payload) == "from task $i"
                    end
                end
                # an idle socket still sees the client go away
                sleep(0.3)
                close(c.sock)
                ev = with_timeout(() -> take!(EVENTS))
                @test ev[1] == :close && ev[2] === ws
            finally
                close(s2)
                wait(s2)
            end
        end

        @test waitfor(() -> F.open_websockets() == 0, 10)
    finally
        close(srv)
        wait(srv)
    end
end

end
