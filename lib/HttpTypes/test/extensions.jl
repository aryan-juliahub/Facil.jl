struct ExtMyType
    x::Int32
end

@testset "extensions::test_extensions" begin
    extensions = Extensions()
    @test repr(extensions) == "Extensions()"

    insert!(extensions, Int32(5))
    insert!(extensions, ExtMyType(10))

    @test get(extensions, Int32) === Int32(5)

    dbg = repr(extensions)
    @test dbg in ("Extensions(Int32, $ExtMyType)", "Extensions($ExtMyType, Int32)")

    ext2 = copy(extensions)

    @test remove!(extensions, Int32) === Int32(5)
    @test get(extensions, Int32) === nothing

    @test get(ext2, Int32) === Int32(5)
    @test get(ext2, ExtMyType) == ExtMyType(10)

    @test get(extensions, Bool) === nothing
    @test get(extensions, ExtMyType) == ExtMyType(10)
end

@testset "extensions::julia api" begin
    e = Extensions()
    @test isempty(e) && length(e) == 0 && e.map === nothing
    @test remove!(e, Int) === nothing
    @test get(e, Int, 7) == 7
    @test_throws KeyError e[Int]
    @test !haskey(e, Int)

    @test insert!(e, 1) === nothing
    @test insert!(e, 2) === 1
    @test e[Int] == 2 && haskey(e, Int) && length(e) == 1 && !isempty(e)

    v = get!(e, Vector{Int})
    push!(v, 3)
    @test get(e, Vector{Int}) == [3]
    @test get!(e, Vector{Int}, [9]) == [3]
    @test get!(() -> "made", e, String) == "made"
    @test get!(e, String, "other") == "made"
    @test get!(e, Float64, 1) === 1.0
    @test length(e) == 4

    @test pop!(e, Float64) === 1.0
    @test pop!(e, Float64, :none) === :none
    @test_throws KeyError pop!(e, Float64)
    @test delete!(e, String) === e && !haskey(e, String)

    other = Extensions()
    insert!(other, 'c')
    insert!(other, 42)
    @test merge!(e, other) === e
    @test e[Char] == 'c' && e[Int] == 42
    @test merge!(Extensions(), Extensions()).map === nothing

    @test empty!(e) === e && isempty(e)
    @test get(e, Int) === nothing
end
