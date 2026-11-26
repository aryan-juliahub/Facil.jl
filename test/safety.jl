# Memory and thread safety at the edges: a released server, a body changed
# while it is queued, a compressed stream shared by tasks, request extensions,
# waits on facil.io locks during a collection, and Ctrl-C inside lock sections.
module SafetyTests

using Facil, Test, Sockets
isdefined(Main, :M6Http) || Main.include(joinpath(@__DIR__, "m6_http.jl"))
using Main.M6Http
const F = Facil

waitfor(f, secs = 10) = timedwait(f, secs; pollint = 0.01) == :ok

const CHILD = raw"""
using Facil, Sockets
const F = Facil
case = ARGS[1]
if case == "ws"
    # send spins on the connection's write lock, which on_ready holds while it collects.
    wsref = Ref{Any}(nothing)
    srv = serve!(0) do req
        websocket(req; on_open = ws -> (wsref[] = ws), on_ready = ws -> GC.gc(false))
    end
    c = connect("127.0.0.1", port(srv))
    write(c, "GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" *
             "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n")
    while !isempty(readline(c)); end
    while wsref[] === nothing; Base.sleep(0.01); end
    ws = wsref[]
    Threads.@spawn try
        while true; readavailable(c); end
    catch
    end
    msg = rand(UInt8, 16 * 1024)
    sender = Threads.@spawn begin
        t0 = time()
        while isopen(ws) && time() - t0 < 3
            F.pending_bytes(ws) > 256 * 1024 ? yield() : F.send(ws, msg)
        end
    end
    wait(sender)
elseif case == "unsubscribe"
    # unsubscribe waits for a delivery in progress, which collects.
    F.ensure_reactor()
    let t0 = time()
        pub = Threads.@spawn while time() - t0 < 3
            publish("c", "x"); Base.sleep(0.0002)
        end
        while time() - t0 < 3
            sub = subscribe(m -> (Libc.systemsleep(0.001); GC.gc(false)), "c")
            Base.sleep(0.002)
            unsubscribe(sub)
        end
        wait(pub)
    end
elseif case == "sigint"
    # Ctrl-C lands on thread 1, here inside on_reactor's lock section or out of it.
    # A lock left held by the interrupt stays held; the reactor takes it briefly.
    function still_held()
        t = time()
        while time() - t < 1
            try
                islocked(F.POSTED_LOCK) || return false
                Libc.systemsleep(0.01)
            catch e
                e isa InterruptException || rethrow()
            end
        end
        true
    end
    stop(killer) = (ccall(:signal, Ptr{Cvoid}, (Cint, Ptr{Cvoid}), 2, Ptr{Cvoid}(1)); process_running(killer) && kill(killer, Base.SIGKILL))
    function interrupt_loop()
        F.ensure_reactor()
        pid, ints, held, t0 = getpid(), 0, false, time()
        killer = run(pipeline(`sh -c "while kill -INT $pid 2>/dev/null; do sleep 0.02; done"`), wait = false)
        while true
            try
                (held || time() - t0 >= 15) && break
                for _ in 1:10_000
                    F.on_reactor(() -> nothing)
                end
            catch e
                e isa InterruptException || rethrow()
                ints += 1
                islocked(F.POSTED_LOCK) && (stop(killer); held = still_held())
            end
        end
        stop(killer)
        for _ in 1:3
            try
                Base.sleep(0.05)
            catch
            end
        end
        println(ints > 0 && !held ? "UNLOCKED" : "HELD $ints")
    end
    Base.exit_on_sigint(false)
    interrupt_loop()
end
println("OK")
"""

# Connects to `port` until the server's connection gets the uuid that the
# paused request had (same fd, counter wrapped), then waits on that one.
const CHURN = raw"""
using Sockets
port, fd = parse(Int, ARGS[1]), parse(Int, ARGS[2])
readline(stdin)
function body_of(s)
    n = 0
    while true
        l = readline(s)
        isempty(l) && break
        k, v = split(l, ':'; limit = 2)
        lowercase(k) == "content-length" && (n = parse(Int, strip(v)))
    end
    String(read(s, n))
end
let target = -1
    for i in 1:700
        s = connect("127.0.0.1", port)
        write(s, "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 70000\r\n\r\n" * "x"^70000)
        readline(s)
        u = parse(Int, body_of(s))
        if target == -1
            u >> 8 == fd || (println("OTHER FD"); exit())
            target = (u >> 8) << 8 | ((u - 2) & 0xff)
        end
        if u == target
            println("MATCH"); flush(stdout)
            t = @async read(s)
            timedwait(() -> istaskdone(t), 3.0)
            println("GOT ", istaskdone(t) ? length(fetch(t)) : 0)
            exit()
        end
        closewrite(s); read(s); close(s)
    end
    println("NO MATCH")
end
"""

# The child's output lines joined, "HUNG" if it did not finish within `limit`
# seconds, or "FORCED" if Julia forced a SIGINT through (it does so for rapid
# repeats, at any instruction, which no lock section can defer).
function child(case; limit = 90)
    cmd = `$(Base.julia_cmd()) -t 4 --project=$(Base.active_project()) --startup-file=no -e $CHILD $case`
    out, err = Pipe(), IOBuffer()
    proc = run(pipeline(ignorestatus(cmd); stdout = out, stderr = err); wait = false)
    close(out.in)
    lines = String[]
    reader = @async (for l in eachline(out); push!(lines, l); end)
    status = timedwait(() -> process_exited(proc), Float64(limit); pollint = 0.05)
    status === :ok || (kill(proc, Base.SIGKILL); wait(proc))
    wait(reader)
    occursin("Force throwing a SIGINT", String(take!(err))) && return "FORCED"
    status === :ok ? join(lines, " ") : "HUNG"
end

@testset "Safety" begin
    @testset "a released server is not reached through its pointer" begin
        s = serve!(req -> "x", 0)
        key = pointer_from_objref(s)
        close(s)
        wait(s)
        @test waitfor(() -> !haskey(F.LIVE, key))
        @test (@atomic s.cserver) == C_NULL
        @test F.connections(s) == 0
        @test !F.is_tls(s)
        close(s)
        close(s; grace = 1)
        @test !isopen(s)
    end

    @testset "a vector body changed while it is queued" begin
        n = 8 << 20
        bodies = Channel{Vector{UInt8}}(1)
        s = serve!(0; inline = true) do req
            b = fill(UInt8('a'), n)
            put!(bodies, b)
            Response(StatusCodes.OK, b)
        end
        c = connect("127.0.0.1", port(s))
        write(c, "GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        b = take!(bodies)
        @test waitfor(() -> F.pinned_bodies() > 0)
        if VERSION >= v"1.11-"
            append!(b, zeros(UInt8, 2n))
            @test length(b) == 3n
        else
            @test_throws ErrorException append!(b, zeros(UInt8, 2n))
            @test_throws ErrorException empty!(b)
        end
        for _ in 1:3
            junk = [fill(0xbb, n) for _ in 1:4]
            GC.gc()
        end
        readuntil(c, "\r\n\r\n")
        @test read(c, n) == fill(UInt8('a'), n)
        @test waitfor(() -> F.pinned_bodies() == 0)
        resize!(b, 10)
        @test length(b) == 10
        close(c)
        close(s)
    end

    @testset "a compressed stream written by several tasks" begin
        piece = Vector{UInt8}(repeat("0123456789abcdef", 1024))
        late = Channel{Any}(1)
        s = serve!(0) do req
            stream(req; compress = :zstd, headers = [header.CONTENT_TYPE => "text/plain"]) do io
                @sync for _ in 1:4
                    Threads.@spawn for _ in 1:50
                        write(io, piece)
                    end
                end
                put!(late, Threads.@spawn begin
                    k = 0
                    try
                        while true
                            write(io, piece)
                            k += 1
                            Base.sleep(0.0005)
                        end
                    catch e
                        e isa Base.IOError || rethrow()
                    end
                    k
                end)
                Base.sleep(0.02)
            end
        end
        r = get1(port(s), "/"; headers = ["accept-encoding" => "zstd"])
        @test r.status == 200
        body = F.unzstd(r.body)
        m = length(piece)
        @test length(body) % m == 0 && length(body) >= 200m
        @test all(i -> view(body, i:i+m-1) == piece, 1:m:length(body))
        @test fetch(take!(late)) isa Int
        close(s)
    end

    @testset "a streamed request's extensions belong to its handler" begin
        seen = Channel{Int}(1)
        s = serve!(0; before_body = h -> Stream()) do req
            n = sum(length, body_chunks(req))
            Base.sleep(0.1)
            put!(seen, length(F.extensions(req)))
            string(n)
        end
        r = get1(port(s), "/"; method = "POST", body = "x"^200_000)
        @test String(copy(r.body)) == "200000"
        @test take!(seen) == 1
        close(s)
    end

    @testset "a late resume after the connection's uuid was reused" begin
        uuids = Channel{Int}(1)
        gate = Channel{Nothing}(1)
        s1 = serve!(0; before_body = h -> Stream()) do req
            put!(uuids, body_stream(req).uuid)
            take!(gate)
            "late"
        end
        s2 = serve!(req -> string(body_stream(req).uuid), 0; inline = true, before_body = h -> Stream())
        a = connect("127.0.0.1", port(s1))
        write(a, "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 70000\r\n\r\n" * "x"^70000)
        fd = take!(uuids) >> 8
        @test waitfor(() -> F.paused_requests() == 1)
        cmd = `$(Base.julia_cmd()) --startup-file=no -e $CHURN $(port(s2)) $fd`
        p = open(pipeline(cmd; stderr = devnull), "r+")
        close(s1)
        wait(s1)
        # Every lower descriptor is taken, so the next connection gets the paused one's.
        dummies = Cint[]
        while (d = ccall(:open, Cint, (Cstring, Cint), "/dev/null", 0)) < fd
            push!(dummies, d)
        end
        ccall(:close, Cint, (Cint,), d)
        println(p, "go")
        out = String[]
        for l in eachline(p)
            push!(out, l)
            l == "MATCH" && put!(gate, nothing)
        end
        foreach(d -> ccall(:close, Cint, (Cint,), d), dummies)
        isready(gate) || put!(gate, nothing)
        if "MATCH" in out
            @test last(out) == "GOT 0"
        else
            @info "uuid reuse not reached; the late resume was not exercised" out
        end
        @test waitfor(() -> F.paused_requests() == 0)
        close(a)
        close(s2)
    end

    @testset "waits on facil.io locks let a collection run" begin
        @test child("ws") == "OK"
        @test child("unsubscribe") == "OK"
    end

    @testset "Ctrl-C inside a lock section" begin
        r = child("sigint")
        if r == "FORCED"
            @info "Julia forced a SIGINT through; the lock-section check was not exercised"
        else
            @test r == "UNLOCKED OK"
        end
    end
end

end
