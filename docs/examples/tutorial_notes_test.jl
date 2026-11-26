using Test, Facil, JSON
import Downloads

include(joinpath(@__DIR__, "tutorial_notes.jl"))

function call(server, method, target; body = nothing)
    out = IOBuffer()
    r = Downloads.request("http://127.0.0.1:$(port(server))$target"; method, output = out,
                          input = body === nothing ? nothing : IOBuffer(body), throw = false)
    (status = r.status, headers = Dict(r.headers), body = String(take!(out)))
end

@testset "notes API" begin
    server = serve!(app, 0)
    try
        r = call(server, "POST", "/notes"; body = """{"title": "Milk", "text": "2 litres"}""")
        @test r.status == 201
        @test r.headers["location"] == "/notes/1"
        @test JSON.parse(r.body)["title"] == "Milk"

        @test call(server, "POST", "/notes"; body = "{oops").status == 400
        @test call(server, "POST", "/notes"; body = """{"text": "no title"}""").status == 422

        r = call(server, "GET", "/notes?q=mi")
        @test r.status == 200
        @test length(JSON.parse(r.body)) == 1
        @test isempty(JSON.parse(call(server, "GET", "/notes?q=bread").body))

        @test call(server, "GET", "/notes/1").status == 200
        @test call(server, "GET", "/notes/99").status == 404
        @test call(server, "PUT", "/notes/1").headers["allow"] == "GET, DELETE"
        @test call(server, "DELETE", "/notes/1").status == 204
        @test call(server, "GET", "/notes/1").status == 404
    finally
        close(server)
    end
end
