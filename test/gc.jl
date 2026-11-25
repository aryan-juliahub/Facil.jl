using Facil, Test

@testset "GC: headroom and per-request allocations" begin
    @testset "gc_headroom!" begin
        @test_throws ArgumentError Facil.gc_headroom!(-1)
        n = Facil.gc_headroom!(0)
        @test Facil.gc_headroom!(n + 2^20) == n + 2^20
        @test Facil.gc_headroom!(1) == n + 2^20
    end

    @testset "pin table counts repeated sends of one body" begin
        b = "shared body"
        p = Ptr{UInt8}(pointer(b))
        n0 = Facil.pinned_bodies()
        Facil.pin!(b, p); Facil.pin!(b, p); Facil.pin!(b, p)
        @test Facil.pinned_bodies() == n0 + 1
        Facil.body_released(Ptr{Cvoid}(p)); Facil.body_released(Ptr{Cvoid}(p))
        @test Facil.pinned_bodies() == n0 + 1
        Facil.body_released(Ptr{Cvoid}(p))
        @test Facil.pinned_bodies() == n0
        f(b, p) = (Facil.pin!(b, p); Facil.body_released(Ptr{Cvoid}(p)))
        f(b, p)
        @test (@allocated f(b, p)) == 0
    end

    @testset "server options read through an untyped Server" begin
        srv = Facil.Server{typeof(identity)}(identity, "", 0, Facil.ServerOptions(), C_NULL, Facil.CLOSED, Base.Event())
        g(@nospecialize(s::Facil.Server)) = s.options.inline
        g(srv)
        @test (@allocated g(srv)) == 0
    end
end
