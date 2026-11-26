using Facil, Test
import Downloads   # not `using`: Downloads exports its own `Response`

#= snippet: app =#
# The application: a plain function from a request to a response.
function app(req)
    m, p = method(req), path(uri(req))
    if m == Methods.GET && p == "/health"
        Response(StatusCodes.OK, "ok")
    elseif m == Methods.POST && p == "/shout"
        isempty(body(req)) && return Response(StatusCodes.BAD_REQUEST, "empty body")
        Response(StatusCodes.OK, uppercase(body(req)); headers = [header.CONTENT_TYPE => "text/plain"])
    else
        Response(StatusCodes.NOT_FOUND, "not found")
    end
end
#= end =#

#= snippet: unit =#
# Unit tests: build a request, call the handler, look at the response.
# No server, no sockets. Pass `body = ""` for requests without a body, as the
# server does, so the handler sees a `Request{String}`.
@testset "handler" begin
    res = app(Request(Methods.GET, "/health", ""))
    @test status(res) == StatusCodes.OK
    @test body(res) == "ok"

    res = app(Request(Methods.POST, "/shout", "hello"; headers = ["content-type" => "text/plain"]))
    @test status(res) == 200
    @test body(res) == "HELLO"
    @test headers(res)[header.CONTENT_TYPE] == "text/plain"

    @test status(app(Request(Methods.POST, "/shout", ""))) == StatusCodes.BAD_REQUEST
    @test status(app(Request(Methods.DELETE, "/health", ""))) == StatusCodes.NOT_FOUND
end
#= end =#

#= snippet: client =#
# A small client on Downloads (a standard library): returns the status and the body.
function fetch_url(url; method = "GET", body = nothing, headers = Pair{String,String}[])
    out = IOBuffer()
    input = body === nothing ? nothing : IOBuffer(body)
    res = Downloads.request(url; method, input, output = out, headers, throw = false)
    res isa Downloads.RequestError && throw(res)
    (status = res.status, headers = Dict(res.headers), body = String(take!(out)))
end
#= end =#

#= snippet: e2e =#
# End-to-end tests: a real server on a free port (port 0), closed in `finally`.
@testset "server" begin
    server = serve!(app, "127.0.0.1", 0)
    try
        base = "http://127.0.0.1:$(port(server))"

        res = fetch_url(base * "/health")
        @test res.status == 200
        @test res.body == "ok"
        @test res.headers["content-type"] == "text/plain; charset=utf-8"

        res = fetch_url(base * "/shout"; method = "POST", body = "hello")
        @test res.status == 200
        @test res.body == "HELLO"

        @test fetch_url(base * "/nope").status == 404
    finally
        close(server)
        wait(server)
    end
end
#= end =#
