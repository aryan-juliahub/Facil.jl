@testset "request::it_can_map_a_body_from_one_type_to_another" begin
    request = Request(; body="some string")
    mapped_request = map(request) do s
        @test s == "some string"
        UInt32(123)
    end
    @test body(mapped_request) === UInt32(123)
    @test mapped_request isa Request{UInt32}
end

@testset "request: builder examples" begin
    req = Request(; method="GET", uri="https://www.rust-lang.org/", headers=["X-Custom-Foo" => "Bar"])
    @test method(req) === Methods.GET
    @test uri(req) == "https://www.rust-lang.org/"
    @test headers(req)["x-custom-foo"] == "Bar"
    @test body(req) === nothing && req isa Request{Nothing}

    for m in (Methods.GET, Methods.PUT, Methods.POST, Methods.DELETE, Methods.OPTIONS,
              Methods.HEAD, Methods.CONNECT, Methods.PATCH, Methods.TRACE)
        r = Request(m, "https://www.rust-lang.org/")
        @test method(r) === m && uri(r) == "https://www.rust-lang.org/" && body(r) === nothing
    end

    @test method(Request(; method="POST")) === Methods.POST
    @test version(Request(; version=Versions.HTTP_2)) === Versions.HTTP_2
    @test uri(Request()) == "/" && method(Request()) === Methods.GET

    req = Request(; headers=("Accept" => "text/html", "X-Custom-Foo" => "bar"))
    @test headers(req)["Accept"] == "text/html"
    @test headers(req)["X-Custom-Foo"] == "bar"

    req = Request(; headers=["accept" => "a", "Accept" => "b"])
    @test collect(get_all(headers(req), "accept")) == ["a", "b"]

    req = Request(; extensions=("My Extension",))
    @test get(extensions(req), String) == "My Extension"
    req = Request(; extensions=("My Extension", UInt32(5)))
    @test get(extensions(req), String) == "My Extension"
    @test get(extensions(req), UInt32) === UInt32(5)
    insert!(extensions(req), 6)
    @test get(extensions(req), Int) == 6
end

@testset "request: accessors" begin
    request = Request("hello world")
    @test method(request) === Methods.GET
    @test body(request) == "hello world"

    (p, b) = (parts(request), body(request))
    p.method = Methods.POST
    request = Request(p, b)
    @test method(request) === Methods.POST && body(request) == "hello world"

    request = Request{Nothing}()
    @test method(request) === Methods.GET
    request.method = Methods.PUT
    @test method(request) === Methods.PUT
    @test uri(request) == "/"
    request.uri = "/hello"
    @test uri(request) == "/hello"
    @test version(request) === Versions.HTTP_11
    request.version = Versions.HTTP_2
    @test version(request) === Versions.HTTP_2
    @test isempty(headers(request))
    insert!(headers(request), header.HOST, hv"world")
    @test !isempty(headers(request))
    @test get(extensions(request), Int32) === nothing
    insert!(extensions(request), "hello")
    @test get(extensions(request), String) == "hello"

    request = Request{String}()
    @test isempty(body(request))
    request.body *= "hello world"
    @test !isempty(body(request))

    @test body(Request(10)) == 10
    p = parts(Request(nothing))
    @test p.method === Methods.GET

    mapped = map(b -> codeunits(b), Request(; body="some string"))
    @test body(mapped) == codeunits("some string")
end

@testset "request: keyword conversions throw typed errors" begin
    @test_throws InvalidMethod Request(; method="G T")
    @test_throws InvalidMethod Request("G T", "/")
    @test_throws InvalidUri Request(; uri="/a b")
    @test_throws InvalidUriParts Request(; uri=UriParts(scheme=Schemes.HTTP))
    @test_throws InvalidHeaderName Request(; headers=["bad name" => "v"])
    @test_throws InvalidHeaderValue Request(; headers=["x" => "a\nb"])
    @test_throws MethodError Request(; version="HTTP/1.1")
    @test method(Request(; method=b"PURGE")) == "PURGE"
    @test uri(Request(; uri=Uri("/x?y"))) == "/x?y"
    @test uri(Request(; uri=UriParts(path_and_query=PathAndQuery("/p")))) == "/p"
    @test headers(Request(; headers=["content-length" => 0]))["content-length"] == "0"

    r = Request(; body="x")
    @test_throws InvalidMethod (r.method = "G T")
    @test_throws InvalidUri (r.uri = "")
    @test_throws MethodError (r.body = 1)
    @test method(r) === Methods.GET && uri(r) == "/" && body(r) == "x"
    r.headers = ["a" => "1"]
    @test headers(r)["a"] == "1"
    r.extensions = (1.5,)
    @test get(extensions(r), Float64) == 1.5
end

@testset "request: construction forms" begin
    h = HeaderMap(header.ACCEPT => "*/*")
    e = Extensions()
    u = uri"/p?q"
    r = Request(Methods.HEAD, u, Versions.HTTP_10, h, e, UInt8[])
    @test r isa Request{Vector{UInt8}}
    @test headers(r) === h && extensions(r) === e && uri(r) === u
    @test r.method === method(r) && r.version === Versions.HTTP_10

    r = Request(Methods.POST, "/submit", "payload"; headers=[header.CONTENT_TYPE => "text/plain"],
        version=Versions.HTTP_2)
    @test method(r) === Methods.POST && body(r) == "payload" && version(r) === Versions.HTTP_2
    @test headers(r)[header.CONTENT_TYPE] == "text/plain"

    r = Request(; headers=h)
    @test headers(r) === h
    p = parts(r)
    @test p isa RequestParts && headers(p) === h && extensions(p) === extensions(r)
    @test method(p) === Methods.GET && uri(p) == "/" && version(p) === Versions.HTTP_11
    @test Request(p, 1) isa Request{Int}

    p = RequestParts(; method="DELETE", uri="/x")
    @test method(p) === Methods.DELETE && uri(p) == "/x" && isempty(headers(p))
    @test_throws InvalidMethod RequestParts(; method="")

    @test Request{String}() isa Request{String} && body(Request{String}()) == ""
    @test body(Request{Int}()) === 0
    @test body(Request{Vector{UInt8}}()) == UInt8[]
    @test body(Request{String}(; method="PUT", body="b")) == "b"
    @test method(Request{String}(; method="PUT")) === Methods.PUT

    r = Request(Methods.GET, "/a"; headers=["x-id" => "1"])
    @test sprint(show, r) ==
          "Request{Nothing}(method=Methods.GET, uri=uri\"/a\", version=Versions.HTTP_11, headers=HeaderMap(hn\"x-id\" => hv\"1\"), body=nothing)"
    @test sprint(show, parts(r)) ==
          "RequestParts(method=Methods.GET, uri=uri\"/a\", version=Versions.HTTP_11, headers=HeaderMap(hn\"x-id\" => hv\"1\"))"
    r2 = eval(Meta.parse(repr(r)))
    @test r2 isa Request{Nothing} && method(r2) === Methods.GET && uri(r2) == uri(r) && headers(r2) == headers(r)
end
