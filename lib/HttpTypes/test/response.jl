@testset "response::it_can_map_a_body_from_one_type_to_another" begin
    response = Response(; body="some string")
    mapped_response = map(response) do s
        @test s == "some string"
        UInt32(123)
    end
    @test body(mapped_response) === UInt32(123)
    @test mapped_response isa Response{UInt32}
end

@testset "response: builder examples" begin
    response = Response(; status=200, headers=["X-Custom-Foo" => "Bar"])
    @test status(response) === StatusCodes.OK
    @test headers(response)["X-Custom-Foo"] == "Bar"
    @test body(response) === nothing

    @test version(Response(; version=Versions.HTTP_2)) === Versions.HTTP_2

    response = Response(; headers=["Content-Type" => "text/html", "X-Custom-Foo" => "bar",
                                   "content-length" => 0])
    @test headers(response)["content-type"] == "text/html"
    @test headers(response)["content-length"] == "0"
    @test length(headers(response)) == 3

    res = Response(; headers=("Accept" => "text/html", "X-Custom-Foo" => "bar"))
    @test headers(res)["Accept"] == "text/html"
    @test headers(res)["X-Custom-Foo"] == "bar"

    res = Response(; extensions=("My Extension", UInt32(5)))
    @test get(extensions(res), String) == "My Extension"
    @test get(extensions(res), UInt32) === UInt32(5)
end

@testset "response: accessors" begin
    response = Response("hello world")
    @test status(response) === StatusCodes.OK
    @test body(response) == "hello world"

    (p, b) = (parts(response), body(response))
    p.status = StatusCodes.BAD_REQUEST
    response = Response(p, b)
    @test status(response) === StatusCodes.BAD_REQUEST
    @test body(response) == "hello world"

    response = Response{Nothing}()
    @test status(response) === StatusCodes.OK
    response.status = StatusCodes.CREATED
    @test status(response) === StatusCodes.CREATED
    @test version(response) === Versions.HTTP_11
    response.version = Versions.HTTP_2
    @test version(response) === Versions.HTTP_2
    @test isempty(headers(response))
    insert!(headers(response), header.HOST, hv"world")
    @test !isempty(headers(response))
    @test get(extensions(response), Int32) === nothing
    insert!(extensions(response), "hello")
    @test get(extensions(response), String) == "hello"

    response = Response{String}()
    @test isempty(body(response))
    response.body *= "hello world"
    @test !isempty(body(response))

    @test body(Response(10.0)) == 10.0 && body(Response("404")) == "404"
    @test_throws ArgumentError Response(404)
    @test_throws ArgumentError Response(UInt16(404); headers=["x" => "y"])
    @test status(Response(StatusCodes.NOT_FOUND)) === StatusCodes.NOT_FOUND
    @test body(Response(StatusCodes.NOT_FOUND)) === nothing
    @test status(Response(StatusCode(404), 10)) === StatusCodes.NOT_FOUND
    r = Response(StatusCodes.NO_CONTENT; headers=["x" => "y"])
    @test status(r) === StatusCodes.NO_CONTENT && headers(r)["x"] == "y" && body(r) === nothing
    @test parts(Response(nothing)).status === StatusCodes.OK

    mapped = map(b -> codeunits(b), Response(; body="some string"))
    @test body(mapped) == codeunits("some string")
end

@testset "response: conversions and forms" begin
    @test_throws InvalidStatusCode Response(; status=6666)
    @test_throws InvalidStatusCode Response(99, "x")
    @test_throws InvalidStatusCode Response(; status="20x")
    @test_throws InvalidHeaderName Response(; headers=["" => "v"])
    @test_throws InvalidHeaderValue Response(; headers=["x" => "\0"])
    @test status(Response(; status="404")) === StatusCodes.NOT_FOUND
    @test status(Response(UInt16(503), "")) === StatusCodes.SERVICE_UNAVAILABLE

    r = Response(StatusCodes.OK, "hello")
    @test r isa Response{String} && body(r) == "hello"
    r.status = 418
    @test status(r) === StatusCodes.IM_A_TEAPOT
    r.status = "500"
    @test status(r) === StatusCodes.INTERNAL_SERVER_ERROR
    @test_throws InvalidStatusCode (r.status = 1000)
    @test status(r) === StatusCodes.INTERNAL_SERVER_ERROR
    r.body = SubString("abc", 1, 2)
    @test body(r) == "ab" && body(r) isa String

    h = HeaderMap()
    e = Extensions()
    r = Response(StatusCodes.NO_CONTENT, Versions.HTTP_10, h, e, nothing)
    @test headers(r) === h && extensions(r) === e && version(r) === Versions.HTTP_10
    r = Response(StatusCodes.NOT_FOUND, "nf"; headers=[header.CONTENT_TYPE => "text/plain"])
    @test status(r) === StatusCodes.NOT_FOUND && headers(r)[header.CONTENT_TYPE] == "text/plain"

    p = parts(r)
    @test p isa ResponseParts && headers(p) === headers(r) && status(p) === StatusCodes.NOT_FOUND
    @test version(p) === Versions.HTTP_11 && extensions(p) === extensions(r)
    p = ResponseParts(; status=301, headers=[header.LOCATION => "/new"])
    @test status(p) === StatusCodes.MOVED_PERMANENTLY && headers(p)[header.LOCATION] == "/new"
    @test Response(p, "moved") isa Response{String}

    @test body(Response{Vector{UInt8}}()) == UInt8[]
    @test status(Response{String}(; status=201)) === StatusCodes.CREATED

    r = Response(StatusCodes.NOT_FOUND, "nf")
    @test sprint(show, r) ==
          "Response{String}(status=StatusCodes.NOT_FOUND, version=Versions.HTTP_11, headers=HeaderMap(), body=\"nf\")"
    @test sprint(show, parts(r)) ==
          "ResponseParts(status=StatusCodes.NOT_FOUND, version=Versions.HTTP_11, headers=HeaderMap())"
end
