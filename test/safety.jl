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
    Base.exit_on_sigint(false)
    F.ensure_reactor()
    let pid = getpid(), ints = 0, held = false, t0 = time()
        killer = run(pipeline(`sh -c "while kill -INT $pid 2>/dev/null; do sleep 0.003; done"`), wait = false)
        while time() - t0 < 5 && !held
            try
                for _ in 1:10_000
                    F.on_reactor(() -> nothing)
                end
            catch e
                e isa InterruptException || rethrow()
                ints += 1
                held = islocked(F.POSTED_LOCK)
            end
        end
        kill(killer, Base.SIGKILL)
        println(ints > 0 && !held ? "UNLOCKED" : "HELD $ints")
    end
end
println("OK")
"""

# The child's last line, or "HUNG" if it did not finish within `limit` seconds.
function child(case; limit = 90)
    cmd = `$(Base.julia_cmd()) -t 4 --project=$(Base.active_project()) --startup-file=no -e $CHILD $case`
    out = Pipe()
    proc = run(pipeline(ignorestatus(cmd); stdout = out, stderr = devnull); wait = false)
    close(out.in)
    lines = String[]
    reader = @async (for l in eachline(out); push!(lines, l); end)
    status = timedwait(() -> process_exited(proc), Float64(limit); pollint = 0.05)
    status === :ok || (kill(proc, Base.SIGKILL); wait(proc))
    wait(reader)
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

    @testset "waits on facil.io locks let a collection run" begin
        @test child("ws") == "OK"
        @test child("unsubscribe") == "OK"
    end

    # Julia 1.10 forces SIGINTs this frequent through at any instruction, so
    # the child would test Julia's forced throw instead.
    VERSION >= v"1.11-" && @testset "Ctrl-C inside a lock section" begin
        @test child("sigint") == "UNLOCKED OK"
    end
end

end
