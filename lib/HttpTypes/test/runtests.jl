using Test, HttpTypes

@testset "HttpTypes" begin
    for f in ("method", "status", "version", "extensions", "header_name", "header_value",
              "header_map", "uri", "request", "response", "error", "patterns", "julia_surface")
        include("$f.jl")
    end
end
