# Request bodies: every before_body mode, Content-Length and chunked, 0 B to 1 GiB,
# pipelining, limits, 100-continue, aborts and GC. Ports 3700-3719.

using Facil, Test, Sockets
const F = Facil

const BPORTS = 3700:3719
const BTAKEN = Set{Int}()
blistening(p) = !isempty(readchomp(ignorestatus(`lsof -nP -t -iTCP:$p -sTCP:LISTEN`)))
function bport()
    for p in BPORTS
        (p in BTAKEN || blistening(p)) && continue
        push!(BTAKEN, p)
        return p
    end
    error("no free port in $BPORTS")
end

crc(x, c::UInt32 = UInt32(0)) = Base._crc32c(x, c)

mutable struct Tally
    n::Int
    crc::UInt32
end
const CALLBACKS = Dict{String,Tally}()
const CB_LOCK = ReentrantLock()

function choose(head)
    p = path(uri(head))
    startswith(p, "/stream") && return Stream()
    startswith(p, "/spool") && return Spool()
    startswith(p, "/reject") && return Reject(401)
    startswith(p, "/throw") && error("before_body failed on purpose")
    if startswith(p, "/callback")
        t = Tally(0, 0)
        id = String(something(get(headers(head), "x-id", nothing), hv"none"))
        lock(() -> (CALLBACKS[id] = t), CB_LOCK)
        return Stream(c -> (t.n += length(c); t.crc = crc(c, t.crc)))
    end
    Buffer()
end

function summarize(io::IO)
    n, c = 0, UInt32(0)
    for chunk in F.BodyChunks(io)
        n += length(chunk)
        c = crc(chunk, c)
    end
    "$n $c"
end

function bodyapp(req)
    p = path(uri(req))
    if startswith(p, "/callback")
        id = String(something(get(headers(req), "x-id", nothing), hv"none"))
        t = lock(() -> pop!(CALLBACKS, id, nothing), CB_LOCK)
        t === nothing && return "0 0"
        return "$(t.n) $(t.crc)"
    elseif startswith(p, "/stream") || startswith(p, "/spool")
        return summarize(body_stream(req))
    elseif p == "/echo"
        return Response(StatusCodes.OK, body(req))
    end
    b = body(req)
    "$(sizeof(b)) $(crc(b))"
end

# ---- a small HTTP/1.1 client over a raw socket

const BLOCK = let v = Vector{UInt8}(undef, 1 << 20)
    x = UInt32(12345)
    for i in eachindex(v)
        x = x * UInt32(1103515245) + UInt32(12345)
        v[i] = (x >> 16) % UInt8
    end
    v
end

# The test body of `n` bytes is BLOCK repeated; its length and checksum.
function expected(n::Int)
    c, left = UInt32(0), n
    while left > 0
        k = min(left, length(BLOCK))
        c = crc(view(BLOCK, 1:k), c)
        left -= k
    end
    "$n $c"
end

function write_body(s, n::Int; chunked::Bool, piece::Int = 1 << 20)
    left, off = n, 0
    while left > 0
        k = min(left, piece, length(BLOCK) - off)
        chunked && write(s, string(k, base = 16), "\r\n")
        write(s, view(BLOCK, off+1:off+k))
        chunked && write(s, "\r\n")
        left -= k
        off = (off + k) % length(BLOCK)
    end
    chunked && write(s, "0\r\n\r\n")
    nothing
end

head_of(path, n; chunked, extra = "") =
    "POST $path HTTP/1.1\r\nHost: x\r\n$(chunked ? "Transfer-Encoding: chunked" : "Content-Length: $n")\r\n$(extra)\r\n"

function read_response(s)
    line = readline(s)
    isempty(line) && eof(s) && return (0, "")
    status = parse(Int, split(line)[2])
    len = 0
    while true
        l = readline(s)
        isempty(l) && break
        k, v = split(l, ':'; limit = 2)
        lowercase(strip(k)) == "content-length" && (len = parse(Int, strip(v)))
    end
    status, String(read(s, len))
end

function post(port, path, n; chunked = false, extra = "", piece = 1 << 20)
    s = Sockets.connect("127.0.0.1", port)
    try
        w = @async begin
            write(s, head_of(path, n; chunked, extra))
            write_body(s, n; chunked, piece)
        end
        r = read_response(s)
        wait(w)
        r
    finally
        close(s)
    end
end

# Sends `payload` and collects whatever comes back for `secs`: the statuses seen
# and whether the server closed the connection.
function raw(port, payload; secs = 1.5)
    s = Sockets.connect("127.0.0.1", port)
    buf = IOBuffer()
    closed = Threads.Atomic{Bool}(false)
    @async try
        while !eof(s)
            write(buf, readavailable(s))
        end
        closed[] = true
    catch
        closed[] = true
    end
    @async try
        write(s, payload)
    catch
    end
    timedwait(() -> closed[], secs; pollint = 0.02)
    c = closed[]
    isopen(s) && close(s)
    txt = String(take!(buf))
    [parse(Int, m[1]) for m in eachmatch(r"HTTP/1\.1 (\d{3})", txt)], c, txt
end

big(n) = repeat("z", n)
curlok(p) = readchomp(`curl -s -X POST --data-binary abc http://127.0.0.1:$p/buffer`) == "3 $(crc("abc"))"

@testset "request bodies" begin
    p = bport()
    srv = serve!(bodyapp, "127.0.0.1", p; before_body = choose, max_body_size = 2^31,
                 body_in_memory = 2^31)
    pl = bport()
    lim = serve!(bodyapp, "127.0.0.1", pl; before_body = choose, max_body_size = 1 << 20,
                 body_in_memory = 256 << 10)

    @testset "sizes x modes x framing" begin
        sizes = [0, 1, 100, 8191, 8192, 70_000, 1 << 20, 10 << 20 + 3]
        for mode in ("/buffer", "/stream", "/callback", "/spool"), n in sizes, chunked in (false, true)
            id = string(mode, n, chunked)
            r = post(p, mode, n; chunked, extra = "x-id: $id\r\n", piece = 16 << 10)
            ok = r == (200, expected(n)) || (n == 0 && !chunked && r[1] == 200)
            ok || @info "mismatch" mode n chunked r
            @test ok
        end
        @test F.pending_bodies() == 0
    end

    @testset "100 MiB and 1 GiB" begin
        for (mode, n) in (("/buffer", 100 << 20), ("/stream", 100 << 20), ("/spool", 100 << 20),
                          ("/callback", 1 << 30), ("/buffer", 1 << 30))
            for chunked in (false, true)
                @test post(p, mode, n; chunked, extra = "x-id: big$mode$chunked\r\n") == (200, expected(n))
            end
            GC.gc()
        end
        @test F.pending_bodies() == 0
    end

    @testset "pipelined uploads" begin
        for mode in ("/buffer", "/stream", "/callback", "/spool")
            reqs = [(n, isodd(i)) for (i, n) in enumerate([0, 5, 9000, 70_000, 300_000, 1, 20_000, 2 << 20, 77, 12_345])]
            s = Sockets.connect("127.0.0.1", p)
            w = @async for (i, (n, ch)) in enumerate(reqs)
                write(s, head_of(mode, n; chunked = ch, extra = "x-id: pipe$mode$i\r\n"))
                write_body(s, n; chunked = ch, piece = 4096)
            end
            got = [read_response(s) for _ in reqs]
            wait(w)
            close(s)
            @test all(map(((n, _), r) -> r == (200, expected(n)) || (n == 0 && r[1] == 200), reqs, got))
        end
    end

    @testset "echo keeps the bytes" begin
        r = post(p, "/echo", 300_000)
        @test r[1] == 200 && codeunits(r[2]) == BLOCK[1:300_000]
    end

    @testset "max_body_size and body_in_memory: one 413, then closed" begin
        st, closed, _ = raw(pl, head_of("/buffer", 2 << 20; chunked = false) * big(2 << 20))
        @test st == [413] && closed
        st, closed, _ = raw(pl, head_of("/buffer", 2 << 20; chunked = false))
        @test st == [413] && closed
        ch = "10000\r\n" * big(65536) * "\r\n"
        st, closed, _ = raw(pl, head_of("/stream", 0; chunked = true) * ch^32 * "0\r\n\r\n")
        @test st == [413] && closed
        st, closed, _ = raw(pl, head_of("/buffer", 300_000; chunked = false) * big(300_000))
        @test st == [413] && closed
        st, closed, _ = raw(pl, head_of("/buffer", 0; chunked = true) * ch^5 * "0\r\n\r\n")
        @test st == [413] && closed
        st, closed, _ = raw(pl, head_of("/stream", 900_000; chunked = false) * big(900_000))
        @test st == [200] && !closed
        st, closed, _ = raw(pl, head_of("/buffer", 200_000; chunked = false) * big(200_000))
        @test st == [200] && !closed
    end

    @testset "Reject and before_body errors" begin
        st, closed, _ = raw(p, head_of("/reject", 5 << 20; chunked = false) * big(5 << 20))
        @test st == [401] && closed
        st, closed, _ = raw(p, head_of("/reject", 10; chunked = false) * big(10))
        @test st == [401] && closed
        st, closed, _ = raw(p, head_of("/reject", 0; chunked = true) * "a\r\n" * big(10) * "\r\n0\r\n\r\n")
        @test st == [401] && closed
        st, closed, _ = raw(p, head_of("/throw", 100_000; chunked = false) * big(100_000))
        @test st == [500] && closed
        st, closed, _ = raw(p, head_of("/throw", 10; chunked = false) * big(10))
        @test st == [500] && closed
        @test curlok(p)
    end

    @testset "Expect: 100-continue" begin
        st, closed, txt = raw(p, head_of("/buffer", 50_000; chunked = false, extra = "Expect: 100-continue\r\n"); secs = 1.0)
        @test st == [100] && !closed
        st, closed, txt = raw(p, head_of("/reject", 50_000; chunked = false, extra = "Expect: 100-continue\r\n"); secs = 1.0)
        @test st == [401] && closed
        st, closed, txt = raw(pl, head_of("/buffer", 300_000; chunked = false, extra = "Expect: 100-continue\r\n"); secs = 1.0)
        @test st == [413] && closed
        out = read(pipeline(`curl -s -H 'Expect: 100-continue' --data-binary @- http://127.0.0.1:$p/buffer`; stdin = devnull), String)
        @test out == "0 0"
        f = tempname()
        write(f, BLOCK)
        @test readchomp(`curl -s -H 'Expect: 100-continue' --data-binary @$f http://127.0.0.1:$p/buffer`) == expected(1 << 20)
        rm(f)
    end

    @testset "uploads cut off mid-body" begin
        a0 = F.BODY_ABORTS[]
        cut = 0
        for mode in ("/buffer", "/stream", "/callback", "/spool"), chunked in (false, true)
            s = Sockets.connect("127.0.0.1", p)
            write(s, head_of(mode, 5 << 20; chunked, extra = "x-id: cut$mode\r\n"))
            chunked && write(s, "100000\r\n")
            write(s, view(BLOCK, 1:300_000))
            # A connection closed before the server first reads it is dropped unread.
            started = timedwait(() -> F.pending_bodies() == 1, 5; pollint = 0.005) == :ok
            close(s)
            cut += started && timedwait(() -> F.pending_bodies() == 0, 5; pollint = 0.005) == :ok
        end
        @test cut == 8
        @test F.pending_bodies() == 0
        @test F.BODY_ABORTS[] - a0 == 8
        lock(() -> empty!(CALLBACKS), CB_LOCK)
        @test post(p, "/buffer", 100_000) == (200, expected(100_000))
    end

    @testset "GC forced during 1000 uploads" begin
        stop = Threads.Atomic{Bool}(false)
        gcs = @async while !stop[]
            GC.gc(false)
            sleep(0.002)
        end
        modes = ("/buffer", "/stream", "/callback", "/spool")
        bad = Threads.Atomic{Int}(0)
        @sync for c in 1:8
            @async for i in 1:125
                n = (i * 7919 + c * 104729) % 200_000
                mode = modes[(i + c) % 4 + 1]
                r = post(p, mode, n; chunked = isodd(i), extra = "x-id: gc$c-$i\r\n", piece = 8192)
                r == (200, expected(n)) || (n == 0 && r[1] == 200) || Threads.atomic_add!(bad, 1)
            end
        end
        stop[] = true
        wait(gcs)
        @test bad[] == 0
        @test F.pending_bodies() == 0
    end

    close(srv); close(lim)
    wait(srv); wait(lim)
end

@testset "streamed bodies on task handlers (subprocess, 4 threads)" begin
    p = bport()
    script = """
    using Facil, Sockets
    const SEEN = Threads.Atomic{Int}(0)
    function app(req)
        p = path(uri(req))
        if p == "/slow"
            n = 0
            for c in body_chunks(req)
                n += length(c)
                Libc.systemsleep(0.002)
            end
            return "\$n \$(Base.gc_live_bytes() >> 20)"
        elseif p == "/early"
            read(body_stream(req), 10)
            return "early"
        elseif p == "/abort"
            try
                for c in body_chunks(req) end
            catch e
                e isa Facil.BodyAborted && Threads.atomic_add!(SEEN, 1)
            end
            return "x"
        elseif p == "/seen"
            return string(SEEN[])
        elseif p == "/keep"
            kept = collect(body_chunks(req))
            GC.gc(); GC.gc()
            c = UInt32(0)
            for k in kept; c = Base._crc32c(k, c); end
            return "\$(sum(length, kept; init = 0)) \$c"
        end
        n = 0
        for c in body_chunks(req); n += length(c); end
        string(n)
    end
    srv = serve!(app, "127.0.0.1", $p; before_body = h -> Stream(high_water = 1 << 20),
                 max_body_size = 1 << 30, inline = false)
    println("READY ", srv.options.inline); flush(stdout)
    wait(srv)
    """
    proc = open(`$(Base.julia_cmd()) -t 4 --project=$(Base.active_project()) --startup-file=no -e $script`, "r")
    try
        line = readline(proc)
        @test line == "READY false"
        rss(pid) = parse(Int, strip(read(`ps -o rss= -p $pid`, String))) ÷ 1024
        pid = getpid(proc)
        r0 = rss(pid)
        r = post(p, "/slow", 200 << 20; piece = 1 << 20)
        @test r[1] == 200 && split(r[2])[1] == string(200 << 20)
        @test rss(pid) - r0 < 150
        @test post(p, "/count", 3 << 20; chunked = true) == (200, string(3 << 20))
        @test post(p, "/early", 50 << 20) == (200, "early")
        @test post(p, "/count", 1000) == (200, "1000")
        # Chunks a handler keeps stay intact while later uploads reuse pooled blocks.
        for n in (3 << 20, 5 << 20), _ in 1:4
            @test post(p, "/keep", n) == (200, expected(n))
        end
        for _ in 1:3
            s = Sockets.connect("127.0.0.1", p)
            write(s, head_of("/abort", 50 << 20; chunked = false))
            write(s, view(BLOCK, 1:200_000))
            sleep(0.2)
            close(s)
        end
        sleep(0.5)
        @test post(p, "/seen", 0)[2] == "3"
    finally
        kill(proc, Base.SIGKILL)
        wait(proc)
    end
end
