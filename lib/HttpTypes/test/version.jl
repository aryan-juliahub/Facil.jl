@testset "version::doc examples" begin
    http11 = Versions.HTTP_11
    http2 = Versions.HTTP_2
    @test http11 != http2
    @test string(http2) == "HTTP/2.0" && repr(http2) == "Versions.HTTP_2"
end

@testset "version::debug output" begin
    vs = (Versions.HTTP_09, Versions.HTTP_10, Versions.HTTP_11, Versions.HTTP_2, Versions.HTTP_3)
    @test [string(v) for v in vs] == ["HTTP/0.9", "HTTP/1.0", "HTTP/1.1", "HTTP/2.0", "HTTP/3.0"]
    @test [repr(v) for v in vs] ==
          ["Versions.HTTP_09", "Versions.HTTP_10", "Versions.HTTP_11", "Versions.HTTP_2", "Versions.HTTP_3"]
    @test string(Versions.HTTP_10) == "HTTP/1.0"
end

@testset "version::ordering, default and hashing" begin
    @test Versions.HTTP_09 < Versions.HTTP_10 < Versions.HTTP_11 < Versions.HTTP_2 < Versions.HTTP_3
    @test sort([Versions.HTTP_3, Versions.HTTP_09, Versions.HTTP_11]) == [Versions.HTTP_09, Versions.HTTP_11, Versions.HTTP_3]
    @test Version() === Versions.HTTP_11
    @test length(Set([Versions.HTTP_11, Version(), Versions.HTTP_2])) == 2
end
