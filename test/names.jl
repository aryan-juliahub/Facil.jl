# Every HttpTypes name that Facil re-exports is the HttpTypes binding itself.

module NamesTests

using Test, Facil, HttpTypes

@testset "re-exported HttpTypes names" begin
    shared = intersect(names(Facil), names(HttpTypes))
    @test :drain! in shared
    @test isempty([n for n in shared if getfield(Facil, n) !== getfield(HttpTypes, n)])
    @test issubset(setdiff(names(HttpTypes), [:HttpTypes]), names(Facil))
    m = HeaderMap{HeaderValue}()
    insert!(m, header.ACCEPT, HeaderValue("text/plain"))
    @test length(collect(drain!(m))) == 1
    @test isempty(m)
end

end
