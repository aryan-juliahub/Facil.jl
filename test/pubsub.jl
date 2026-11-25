# Process-local pub/sub.

module PubSubTests

using Facil, Test
const F = Facil

waitfor(f, secs = 5) = timedwait(f, secs; pollint = 0.01) == :ok

@testset "pub/sub" begin
    @testset "order, channels, unsubscribe" begin
        got = String[]
        l = ReentrantLock()
        a = subscribe(m -> lock(() -> push!(got, "a:" * m), l), "ps-a")
        b = subscribe(m -> lock(() -> push!(got, "b:" * m), l), "ps-b")
        @test isopen(a)
        for i in 1:500
            publish("ps-a", string(i))
        end
        publish("ps-b", UInt8[0x68, 0x69])
        publish("ps-none", "nobody listens")
        @test waitfor(() -> lock(() -> length(got), l) == 501)
        @test filter(startswith("a:"), got) == ["a:$i" for i in 1:500]
        @test "b:hi" in got
        unsubscribe(a)
        @test !isopen(a)
        unsubscribe(a)  # idempotent
        publish("ps-a", "late")
        publish("ps-b", "still")
        @test waitfor(() -> lock(() -> "b:still" in got, l))
        @test !("a:late" in got)
        close(b)
        @test waitfor(() -> isempty(F.LIVE_SUBS))
    end

    @testset "publish from many threads; errors are contained" begin
        n = Threads.Atomic{Int}(0)
        s = subscribe(m -> (m == "boom" && error("boom"); Threads.atomic_add!(n, 1)), "ps-mt")
        publish("ps-mt", "boom")
        @sync for _ in 1:4
            Threads.@spawn for i in 1:1000
                publish("ps-mt", "x")
            end
        end
        @test waitfor(() -> n[] == 4000)
        close(s)
    end

    @testset "spawn = true runs on tasks" begin
        onreactor = Threads.Atomic{Int}(-1)
        s = subscribe(m -> (onreactor[] = F.fjl_on_reactor() ? 1 : 0), "ps-spawn"; spawn = true)
        publish("ps-spawn", "x")
        @test waitfor(() -> onreactor[] >= 0)
        @test onreactor[] == 0
        close(s)
    end
end

end
