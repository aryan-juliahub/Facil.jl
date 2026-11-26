# Core shim tests. Included by runtests.jl; also run as a subprocess script
# (`julia core.jl <scenario> args...`) for scenarios that need their own process.

using Facil, Sockets, Test
const F = Facil

const PORTS = 3420:3439
const TAKEN = Set{Int}()

port_listening(p) = success(pipeline(ignorestatus(`lsof -nP -iTCP:$p -sTCP:LISTEN`); stdout=devnull, stderr=devnull)) &&
                    !isempty(readchomp(ignorestatus(`lsof -nP -t -iTCP:$p -sTCP:LISTEN`)))

function free_port()
    for p in PORTS
        p in TAKEN && continue
        port_listening(p) && continue
        push!(TAKEN, p)
        return p
    end
    error("no free port in $PORTS")
end

const BODY = "Hello, World!"
const N_REQ = Threads.Atomic{Int}(0)
const N_ERR = Threads.Atomic{Int}(0)

send_body(h::Ptr{Cvoid}, s::String) =
    ccall((:http_send_body, F.LIBFJL), Cint, (Ptr{Cvoid}, Ptr{UInt8}, Csize_t), h, s, sizeof(s))

function const_request(h::Ptr{Cvoid})
    try
        Threads.atomic_add!(N_REQ, 1)
        send_body(h, BODY)
    catch
        Threads.atomic_add!(N_ERR, 1)
    end
    nothing
end

function gc_request(h::Ptr{Cvoid})
    try
        n = Threads.atomic_add!(N_REQ, 1)
        v = Vector{Int}(undef, 256)
        for i in eachindex(v)
            v[i] = n + i
        end
        d = Dict{String,Any}()
        for i in 1:24
            d[string("key", i, "_", n)] = string(v[i], "-", repeat("x", i))
        end
        d["vec"] = v
        body = join((d[string("key", i, "_", n)]::String for i in 1:24), ",")
        ok = sum(v) == 256n + 32896 && length(d) == 25 && startswith(body, string(n + 1, "-x,"))
        ok || Threads.atomic_add!(N_ERR, 1)
        send_body(h, ok ? "ok" : "XX")
    catch
        Threads.atomic_add!(N_ERR, 1)
    end
    nothing
end

const N_FINISHED = Threads.Atomic{Int}(0)
const LAST_UDATA = Ref{Ptr{Cvoid}}(C_NULL)
function on_finish(settings::Ptr{Cvoid})
    try
        LAST_UDATA[] = F.fjl_settings_udata(settings)
        Threads.atomic_add!(N_FINISHED, 1)
    catch
    end
    nothing
end

function resume_task(h::Ptr{Cvoid})
    try
        send_body(h, BODY)
    catch
        Threads.atomic_add!(N_ERR, 1)
    end
    nothing
end
fallback(::Ptr{Cvoid}) = (Threads.atomic_add!(N_ERR, 1); nothing)
const RESUME = Ref{Ptr{Cvoid}}(C_NULL)
const FALLBACK = Ref{Ptr{Cvoid}}(C_NULL)
function on_pause(handle::Ptr{Cvoid})
    try
        Threads.@spawn F.fjl_resume(handle, RESUME[], FALLBACK[])
    catch
        Threads.atomic_add!(N_ERR, 1)
    end
    nothing
end
const ON_PAUSE = Ref{Ptr{Cvoid}}(C_NULL)
function paused_request(h::Ptr{Cvoid})
    try
        Threads.atomic_add!(N_REQ, 1)
        ccall((:http_pause, F.LIBFJL), Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}), h, ON_PAUSE[])
    catch
        Threads.atomic_add!(N_ERR, 1)
    end
    nothing
end

function init_callbacks()
    RESUME[] = @cfunction(resume_task, Cvoid, (Ptr{Cvoid},))
    FALLBACK[] = @cfunction(fallback, Cvoid, (Ptr{Cvoid},))
    ON_PAUSE[] = @cfunction(on_pause, Cvoid, (Ptr{Cvoid},))
end

handler_ptr(kind::Symbol) =
    kind === :const ? @cfunction(const_request, Cvoid, (Ptr{Cvoid},)) :
    kind === :gc ? @cfunction(gc_request, Cvoid, (Ptr{Cvoid},)) :
    kind === :pause ? @cfunction(paused_request, Cvoid, (Ptr{Cvoid},)) : error("unknown handler $kind")

listen_fixture(port, kind::Symbol = :const; udata = C_NULL) =
    F.fjl_listen("127.0.0.1", port, F.ListenOptions(handler_ptr(kind);
        on_finish = @cfunction(on_finish, Cvoid, (Ptr{Cvoid},)), udata))

function http_get(port; path = "/", close = true)
    s = Sockets.connect("127.0.0.1", port)
    try
        write(s, "GET $path HTTP/1.1\r\nHost: x\r\n", close ? "Connection: close\r\n" : "", "\r\n")
        head = readuntil(s, "\r\n\r\n")
        status = parse(Int, split(head, ' ')[2])
        m = match(r"(?i)content-length:\s*(\d+)", head)
        body = String(read(s, m === nothing ? 0 : parse(Int, m[1])))
        (status, body)
    finally
        Base.close(s)
    end
end

function refused(port)
    try
        Base.close(Sockets.connect("127.0.0.1", port))
        false
    catch
        true
    end
end

function wait_until(f, timeout)
    t = time()
    while !f()
        time() - t > timeout && return false
        sleep(0.01)
    end
    true
end

this_cmd(threads, args...) = `$(Base.julia_cmd()) --project=$(Base.active_project()) --startup-file=no -t $threads $(@__FILE__) $args`

# ---------------------------------------------------------------------------
# Scenarios run in their own process

"Keep-alive, pipelined load client; prints `RESULT ok bad err`."
function scenario_client(port, secs, conns, depth, expect)
    port = parse(Int, port); secs = parse(Float64, secs)
    conns = parse(Int, conns); depth = parse(Int, depth)
    ok = Threads.Atomic{Int}(0); bad = Threads.Atomic{Int}(0); err = Threads.Atomic{Int}(0)
    req = repeat("GET / HTTP/1.1\r\nHost: x\r\n\r\n", depth)
    deadline = time() + secs
    @sync for _ in 1:conns
        Threads.@spawn try
            s = Sockets.connect("127.0.0.1", port)
            while time() < deadline
                write(s, req)
                for _ in 1:depth
                    head = readuntil(s, "\r\n\r\n")
                    m = match(r"(?i)content-length:\s*(\d+)", head)
                    body = m === nothing ? "" : String(read(s, parse(Int, m[1])))
                    if startswith(head, "HTTP/1.1 200") && body == expect
                        Threads.atomic_add!(ok, 1)
                    else
                        Threads.atomic_add!(bad, 1)
                    end
                end
            end
            Base.close(s)
        catch
            Threads.atomic_add!(err, 1)
        end
    end
    println("RESULT ", ok[], " ", bad[], " ", err[])
end

"Serves the constant reply on `port` until killed (benchmark fixture)."
function scenario_serve(port, threads = "1")
    F.ensure_reactor(threads = parse(Int, threads))
    listen_fixture(parse(Int, port))
    println("SERVING ", port); flush(stdout)
    while true
        sleep(1)
    end
end

"Five stop/start cycles: listeners rebuilt, no fd or listener leak, bounded thread ids."
function scenario_restart(port, threads)
    port = parse(Int, port); threads = parse(Int, threads)
    pid = getpid()
    nfds() = count(==('\n'), read(`lsof -nP -p $pid`, String))
    listeners() = length(split(readchomp(ignorestatus(`lsof -nP -t -a -p $pid -iTCP:$port -sTCP:LISTEN`)), '\n'; keepempty = false))
    @testset "restart x5 ($threads reactor threads)" begin
        fds = Int[]; tids = Int[]
        for cycle in 1:5
            @test F.start_reactor(; threads)
            @test F.fjl_reactor_threads() == threads
            listen_fixture(port)
            @test all(_ -> http_get(port) == (200, BODY), 1:50)
            held = Sockets.connect("127.0.0.1", port)
            write(held, "GET / HTTP/1.1\r\nHost: x\r\n\r\n")
            readuntil(held, "\r\n\r\n")
            @test listeners() == 1
            t = @elapsed @test F.stop_reactor()
            @test t < 1.5
            Base.close(held)
            @test !F.reactor_running()
            @test listeners() == 0
            @test refused(port)
            push!(fds, nfds()); push!(tids, Threads.maxthreadid())
            println("cycle $cycle: stop=$(round(t * 1e3, digits = 1)) ms fds=$(fds[end]) maxthreadid=$(tids[end]) ", F.fjl_stats())
        end
        @test N_FINISHED[] == 5
        @test fds[end] - fds[2] <= 2
        @test tids[end] - tids[1] <= 4 * (threads + 1)
        @test F.fjl_stats().pool_threads == (threads > 1 ? 5 * threads : 0)
        @test N_ERR[] == 0
    end
end

const BUMPS = Threads.Atomic{Int}(0)
bump_counter(::Ptr{Cvoid}, ::Ptr{Cvoid}, ::Ptr{Cvoid}) = (Threads.atomic_add!(BUMPS, 1); nothing)

"Concurrent bursts of posts and pause/resume round trips from several Julia threads."
function scenario_async(port)
    port = parse(Int, port)
    @testset "wake pipe and resume queue ($(Threads.nthreads()) Julia threads)" begin
        F.ensure_reactor()
        counter = BUMPS
        bump = @cfunction(bump_counter, Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}))
        nt = max(Threads.nthreads(), 2)
        worst = 0.0
        total = 0
        for round in 1:300
            per = round % 3 == 0 ? 2000 : rand(1:64)
            t0 = time()
            @sync for _ in 1:nt
                Threads.@spawn for _ in 1:per
                    F.fjl_post(bump, C_NULL, C_NULL) == 0 || error("post refused")
                end
            end
            total += nt * per
            done = wait_until(() -> counter[] == total, 2.0)
            worst = max(worst, time() - t0)
            done || (println("round $round stalled: ", counter[], " of ", total); break)
        end
        @test counter[] == total
        @test worst < 0.5
        println("bursts: $total posts, worst round $(round(worst * 1e3, digits = 2)) ms, ", F.fjl_stats())

        closures = Threads.Atomic{Int}(0)
        @sync for _ in 1:nt
            Threads.@spawn for _ in 1:5000
                F.on_reactor(() -> Threads.atomic_add!(closures, 1))
            end
        end
        @test wait_until(() -> closures[] == nt * 5000, 2.0)

        init_callbacks()
        listen_fixture(port, :pause)
        ok = Threads.Atomic{Int}(0)
        @sync for _ in 1:8
            Threads.@spawn for _ in 1:250
                http_get(port; close = false) == (200, BODY) && Threads.atomic_add!(ok, 1)
            end
        end
        @test ok[] == 2000
        @test N_ERR[] == 0
        @test F.stop_reactor()
    end
end

"Ctrl-C reaches Julia while the reactor runs; with exit_on_sigint the process exits."
function scenario_sigint(port, mode, flag)
    port = parse(Int, port)
    mode == "catch" && Base.exit_on_sigint(false)
    before = F.fjl_sig_disposition(2)
    F.ensure_reactor()
    listen_fixture(port)
    println("DISP SIGINT ", before, " ", F.fjl_sig_disposition(2), " SIGPIPE ", F.fjl_sig_disposition(13))
    caught = reported = 0
    ready = false
    while true
        try
            if !ready
                println("READY"); flush(stdout)
                ready = true
            elseif reported < caught
                reported = caught
                println("CAUGHT ", caught); flush(stdout)
            end
            isfile(flag) && break
            sleep(0.02)
        catch e
            e isa InterruptException || rethrow()
            caught += 1
        end
    end
    status = http_get(port)[1]
    F.stop_reactor()
    println("DONE caught=", caught, " status=", status); flush(stdout)
end

"Exits normally with the reactor and a listener still running."
function scenario_exit(port)
    port = parse(Int, port)
    F.ensure_reactor(threads = 2)
    listen_fixture(port)
    println("STATUS ", http_get(port)[1])
end

if abspath(PROGRAM_FILE) == @__FILE__
    scenario = Symbol("scenario_", ARGS[1])
    getfield(@__MODULE__, scenario)(ARGS[2:end]...)
    exit(0)
end

# ---------------------------------------------------------------------------
# In-process tests

function run_scenario(threads, args...)
    p = run(ignorestatus(this_cmd(threads, args...)))
    success(p)
end

@testset "library" begin
    @test F.fjl_version() == "0.1.0"
    @test occursin("facil.io", F.fjl_build_id())
    println("libfacil_julia ", F.fjl_version(), " (", F.fjl_build_id(), ")")
    @test !F.fjl_on_reactor()
    sigint_before = F.fjl_sig_disposition(2)
    F.ensure_reactor()
    @test F.reactor_running()
    @test F.start_reactor() == false
    @test F.fjl_sig_disposition(13) == 1
    @test F.fjl_sig_disposition(2) == sigint_before
    info = Channel{Tuple{Bool,Int}}(1)
    @test F.on_reactor(() -> put!(info, (F.fjl_on_reactor(), F.fjl_thread_stack_size())))
    on, stack = take!(info)
    @test on
    @test stack >= 8 << 20
    @test F.on_reactor(() -> error("deliberate")) # logged, not fatal
    sleep(0.1)
    @test F.reactor_running()
end

@testset "listener open and close" begin
    port = free_port()
    before = N_FINISHED[]
    uuid = listen_fixture(port; udata = Ptr{Cvoid}(UInt(0x1234)))
    @test uuid >= 0
    @test http_get(port) == (200, BODY)
    @test http_get(port; path = "/x?y=1") == (200, BODY)
    @test_throws SystemError listen_fixture(port)
    @test F.fjl_listen_close(uuid) == 0
    @test wait_until(() -> N_FINISHED[] == before + 2, 2.0)
    @test LAST_UDATA[] == Ptr{Cvoid}(UInt(0x1234))
    @test wait_until(() -> refused(port), 2.0)
    @test F.reactor_running()
    uuid2 = listen_fixture(port)
    @test http_get(port) == (200, BODY)
    F.fjl_listen_close(uuid2)
    @test wait_until(() -> refused(port), 2.0)
    @test N_ERR[] == 0
end

@testset "GC stress: forced collections under load" begin
    port = free_port()
    uuid = listen_fixture(port, :gc)
    secs = parse(Float64, get(ENV, "FACIL_GC_SECS", "10"))
    idle = [@elapsed(GC.gc(true)) for _ in 1:5]
    N_REQ[] = 0; N_ERR[] = 0
    client = open(this_cmd(4, "client", port, secs, 64, 8, "ok"); read = true)
    gcs = Float64[]
    t0 = time()
    while process_running(client) && time() - t0 < secs + 30
        push!(gcs, @elapsed GC.gc(length(gcs) % 3 == 0))
        sleep(0.002)
    end
    out = read(client, String)
    wait(client)
    m = match(r"RESULT (\d+) (\d+) (\d+)", out)
    @test m !== nothing
    ok, bad, err = parse.(Int, m.captures)
    sort!(gcs)
    println("GC stress: $ok ok, $bad bad, $err client errors, $(N_REQ[]) handled, $(length(gcs)) forced GCs ",
            "(median $(round(gcs[end ÷ 2] * 1e3, digits = 2)) ms, max $(round(gcs[end] * 1e3, digits = 2)) ms; ",
            "idle full GC max $(round(maximum(idle) * 1e3, digits = 2)) ms)")
    # A floor on progress, not a benchmark: CI runners share 3-4 vCPUs among
    # the client, the server and the collection loop.
    @test ok >= 1_000 * secs
    @test bad == 0
    @test err == 0
    @test N_ERR[] == 0
    @test length(gcs) >= 100
    @test gcs[end ÷ 2] < 0.05
    F.fjl_listen_close(uuid)
    @test wait_until(() -> refused(port), 2.0)
end

@testset "wake burst and resume queue (subprocess)" begin
    @test run_scenario(4, "async", free_port())
end

@testset "restart (subprocess)" begin
    @test run_scenario(2, "restart", free_port(), 1)
    @test run_scenario(2, "restart", free_port(), 4)
end

@testset "SIGINT (subprocess)" begin
    mktempdir() do dir
        port = free_port()
        flag = joinpath(dir, "finish")
        p = open(this_cmd(1, "sigint", port, "catch", flag); read = true)
        lines = String[]
        while (l = readline(p)) != "READY"
            push!(lines, l)
            eof(p) && break
        end
        for i in 1:3
            sleep(0.2)
            kill(p, Base.SIGINT)
            @test readline(p) == "CAUGHT $i"
        end
        @test http_get(port) == (200, BODY)
        touch(flag)
        rest = read(p, String)
        wait(p)
        @test success(p)
        @test occursin("DONE caught=3 status=200", rest)
        println(join(lines, "\n"))

        port2 = free_port()
        p2 = open(this_cmd(1, "sigint", port2, "exit", flag * "2"); read = true)
        while readline(p2) != "READY"
            eof(p2) && break
        end
        sleep(0.2)
        kill(p2, Base.SIGINT)
        t = time()
        @test wait_until(() -> !process_running(p2), 10.0)
        # A process that is still there prints where its threads are (SIGQUIT).
        process_running(p2) && (kill(p2, Base.SIGQUIT); sleep(3))
        process_running(p2) && kill(p2, Base.SIGKILL)
        println("SIGINT with exit_on_sigint: exited in $(round(time() - t, digits = 2)) s")
        @test !success(p2)
        @test wait_until(() -> refused(port2), 2.0)
    end
end

@testset "exit with the reactor running (subprocess)" begin
    port = free_port()
    out = Pipe()
    t = @elapsed p = run(pipeline(ignorestatus(this_cmd(1, "exit", port)); stdout = out))
    close(out.in)
    @test success(p)
    @test occursin("STATUS 200", read(out, String))
    @test t < 30
    @test refused(port)
end
