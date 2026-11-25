# Facil.sleep, Facil.Timer and every on the C timer thread. Port 3680-3689.

module TimerTests

using Facil, Test
const F = Facil

pct(v, p) = sort(v)[clamp(ceil(Int, p * length(v)), 1, length(v))]

function durations(s, n)
    v = Vector{Float64}(undef, n)
    for i in 1:n
        t = time_ns()
        F.sleep(s)
        v[i] = (time_ns() - t) / 1e6
    end
    v
end

function wait_pending_zero()
    t = time()
    while F.timer_stats().pending != 0
        time() - t > 5 && return false
        Base.sleep(0.01)
    end
    true
end

@testset "timers" begin
    @testset "Facil.sleep accuracy" begin
        F.sleep(0.001)
        for (where, v) in (("this task", durations(0.001, 300)),
                           ("a spawned task", fetch(Threads.@spawn durations(0.001, 300))))
            println("Facil.sleep(1 ms) on $where: p50 ", round(pct(v, 0.5), digits = 3), " ms, p99 ",
                    round(pct(v, 0.99), digits = 3), " ms, min ", round(minimum(v), digits = 3), " ms")
            @test minimum(v) >= 1.0
            @test pct(v, 0.5) < 1.5
        end
        v = durations(0.01, 50)
        @test minimum(v) >= 10.0
        @test pct(v, 0.5) < 11.0
    end

    @testset "edge cases" begin
        @test F.sleep(0) === nothing
        @test F.sleep(-1) === nothing
        @test_throws ArgumentError F.sleep(NaN)
        @test_throws ArgumentError F.Timer(identity, -1)
        @test_throws ArgumentError every(() -> nothing, 0)
    end

    @testset "10,000 concurrent sleepers" begin
        early = Threads.Atomic{Int}(0)
        t = @elapsed @sync for i in 1:10_000
            Threads.@spawn begin
                d = (1 + i % 20) / 1000
                t0 = time_ns()
                F.sleep(d)
                (time_ns() - t0) / 1e9 < d && Threads.atomic_add!(early, 1)
            end
        end
        @test early[] == 0
        @test t < 5
        @test F.timer_stats().pending == 0
    end

    @testset "interrupted sleep" begin
        t = Threads.@spawn F.sleep(10)
        while !istaskstarted(t) || F.timer_stats().pending == 0
            yield()
        end
        schedule(t, InterruptException(); error = true)
        @test_throws TaskFailedException wait(t)
        @test F.timer_stats().pending == 0
        @test minimum(durations(0.002, 20)) >= 2.0
    end

    @testset "Timer and every" begin
        n = Threads.Atomic{Int}(0)
        one = F.Timer(t -> Threads.atomic_add!(n, 1), 0.01)
        @test timedwait(() -> !isopen(one), 5.0) === :ok
        @test n[] == 1

        ticks = Float64[]
        t0 = time_ns()
        rep = F.Timer(t -> push!(ticks, (time_ns() - t0) / 1e6), 0.005; interval = 0.005)
        Base.sleep(0.2)
        close(rep)
        @test !isopen(rep)
        k = length(ticks)
        Base.sleep(0.05)
        @test length(ticks) == k
        @test 20 <= k <= 50
        @test all(>=(5.0), ticks)

        m = Threads.Atomic{Int}(0)
        e = every(() -> (Threads.atomic_add!(m, 1); m[] < 5), 2)
        @test timedwait(() -> !isopen(e), 5.0) === :ok
        @test m[] == 5

        long = every(() -> nothing, 60_000)
        close(long)
        @test timedwait(() -> istaskdone(long.task), 2.0) === :ok

        bad = F.Timer(t -> error("timer failure"), 0.001; interval = 0.001)
        @test timedwait(() -> !isopen(bad), 5.0) === :ok
        @test wait_pending_zero()
    end

    @testset "Facil.sleep on a reactor thread" begin
        p = first(filter(p -> isempty(readchomp(ignorestatus(`lsof -nP -t -iTCP:$p -sTCP:LISTEN`))), 3680:3689))
        srv = serve!(req -> (F.sleep(0.005); string(F.fjl_on_reactor())), p; inline = true)
        t = @elapsed r = read(`curl -s --max-time 10 http://127.0.0.1:$p/`, String)
        @test r == "true"
        @test t >= 0.005
        close(srv)
        wait(srv)
    end
end

end # module
