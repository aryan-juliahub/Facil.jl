@testset "surface: method/status/version/extensions" begin
    @test Methods.GET === HttpMethod("GET")
    @test HttpMethod(b"POST") === Methods.POST
    @test HttpMethod(SubString("xGETx", 2, 4)) === Methods.GET
    @test HttpMethod(view(Vector{UInt8}("xPUTx"), 2:4)) === Methods.PUT
    @test HttpMethod(@view(Vector{UInt8}("xHEADx")[2:2:6])) == "HAx"
    s = "OPTIONS PURGE"
    GC.@preserve s begin
        @test HttpMethod(pointer(s), 7) === Methods.OPTIONS
        @test HttpMethod(pointer(s) + 8, 5) == "PURGE"
        @test tryparse(HttpMethod, pointer(s), 8) === nothing
        @test StatusCode(pointer("404"), 3) === StatusCodes.NOT_FOUND
    end
    @test HttpMethod() === Methods.GET
    @test HttpMethod(Methods.PATCH) === Methods.PATCH
    @test parse(HttpMethod, "DELETE") === Methods.DELETE
    @test HttpMethod("PURGE") == "PURGE"
    @test HttpMethod("PURGE") == HttpMethod("PURGE") && HttpMethod("PURGE") != HttpMethod("PURGa")
    @test HttpMethod("GET") == HttpMethod(b"GET") && HttpMethod("get") != Methods.GET
    @test_throws InvalidMethod HttpMethod("GE T")
    @test InvalidMethod <: HttpError && InvalidStatusCode <: HttpError
    @test sprint(showerror, InvalidMethod()) == "invalid HTTP method"
    @test sprint(showerror, InvalidStatusCode()) == "invalid status code"
    @test is_safe(Methods.GET) && !is_safe(Methods.POST) && !is_safe(HttpMethod("PURGE"))
    @test all(is_safe, (Methods.HEAD, Methods.OPTIONS, Methods.TRACE, Methods.QUERY))
    @test !is_idempotent(HttpMethod("PURGE"))
    @test String(Methods.GET) == "GET" && string(Methods.GET) == "GET" && repr(Methods.GET) == "Methods.GET"
    @test sort([Methods.POST, Methods.GET, HttpMethod("ACL")]) == [HttpMethod("ACL"), Methods.GET, Methods.POST]
    @test hash(HttpMethod("PURGE")) == hash(HttpMethod(b"PURGE")) && hash(Methods.GET) == hash("GET")
    @test length(Set([Methods.GET, HttpMethod("GET"), Methods.POST])) == 2
    @test :GET in names(Methods; all=true) && :QUERY in names(Methods; all=true)
    @test HttpMethod("GET") isa HttpMethod && !(HttpMethod === Base.Method)

    @test StatusCodes.OK === StatusCode(200) === StatusCode("200") === StatusCode(UInt16(200))
    @test StatusCodes.IM_A_TEAPOT == 418 && StatusCodes.NETWORK_AUTHENTICATION_REQUIRED == 511
    @test count(n -> getfield(StatusCodes, n) isa StatusCode, names(StatusCodes; all=true)) == 62
    @test UInt16(StatusCodes.NOT_FOUND) === 0x0194 && Int(StatusCodes.NOT_FOUND) === 404
    @test tryparse(StatusCode, "20x") === nothing && tryparse(StatusCode, 500) === StatusCodes.INTERNAL_SERVER_ERROR
    @test parse(StatusCode, "503") === StatusCodes.SERVICE_UNAVAILABLE
    @test StatusCodes.OK < StatusCodes.NOT_FOUND
    @test hash(StatusCodes.OK) == hash(200) && StatusCodes.OK in Set([200])
    @test string(Versions.HTTP_11) == "HTTP/1.1" && Versions.HTTP_10 < Versions.HTTP_2

    e = Extensions()
    insert!(e, StatusCodes.OK)
    @test e[StatusCode] === StatusCodes.OK
    @test sprint(show, e) == "Extensions(StatusCode)" || sprint(show, e) == "Extensions($(StatusCode))"
end

@testset "surface: headers" begin
    @test InvalidHeaderName <: HttpError && InvalidHeaderValue <: HttpError
    @test ToStrError <: HttpError && MaxSizeReached <: HttpError

    h = HeaderMap()
    @test insert!(h, header.CONTENT_TYPE, "application/json") === nothing
    @test append!(h, header.SET_COOKIE, "a=1") == false
    @test append!(h, "X-Request-Id", "42") == false
    @test append!(h, header.SET_COOKIE, "b=2") == true
    @test h[header.CONTENT_TYPE] == "application/json"
    @test h["Content-Type"] == "application/json"
    @test h["x-request-ID"] == "42"
    @test h[b"X-Request-Id"] == "42"
    @test get(h, "x-missing", nothing) === nothing
    @test get(() -> "dflt", h, "x-missing") == "dflt"
    @test_throws KeyError h["x-missing"]
    @test haskey(h, "SET-COOKIE") && !haskey(h, "bad name")
    @test length(h) == 4 && keys_len(h) == 3
    @test [as_str(k) => to_str(v) for (k, v) in h] ==
          ["content-type" => "application/json", "set-cookie" => "a=1", "set-cookie" => "b=2", "x-request-id" => "42"]
    @test collect(keys(h)) == [header.CONTENT_TYPE, header.SET_COOKIE, HeaderName("x-request-id")]
    @test collect(values(h)) == ["application/json", "a=1", "b=2", "42"]
    h["x-request-id"] = "43"
    @test h["x-request-id"] == "43"
    @test insert!(h, "x-request-id", 44) == "43" && h["x-request-id"] == "44"
    @test copy(h) == h && copy(h) !== h
    delete!(h, header.CONTENT_TYPE)
    @test collect(keys(h)) == [HeaderName("x-request-id"), header.SET_COOKIE]
    @test pop!(h, "set-cookie") == "a=1"
    @test pop!(h, "set-cookie", nothing) === nothing
    @test_throws KeyError pop!(h, "set-cookie")
    @test length(h) == 1
    @test sprint(show, h) == "HeaderMap(hn\"x-request-id\" => hv\"44\")"

    @test HeaderMap("a" => "1", "A" => "2", "b" => "3") ==
          HeaderMap([HeaderName("a") => hv"1", HeaderName("a") => hv"2", HeaderName("b") => hv"3"])
    @test HeaderMap("a" => "1")["a"] == "1"
    @test HeaderMap(Dict("Host" => "x"))[header.HOST] == "x"
    @test HeaderMap{Int}("n" => 1)["n"] === 1

    # extend! with drain! output replaces named keys and appends nameless values.
    src = HeaderMap("a" => "1", "a" => "2", "b" => "3")
    dst = HeaderMap("a" => "0", "c" => "9")
    extend!(dst, drain!(src))
    @test isempty(src)
    @test collect(get_all(dst, "a")) == ["1", "2"] && dst["b"] == "3" && dst["c"] == "9"
    @test collect(keys(dst)) == [hn"a", hn"c", hn"b"]
    extend!(dst, ["a" => "x"])
    @test collect(get_all(dst, "a")) == ["1", "2", "x"]
    @test_throws ArgumentError extend!(HeaderMap(), Pair{Union{Nothing,HeaderName},HeaderValue}[nothing => hv"x"])

    @test as_str(HeaderName("X-Request-Id")) == "x-request-id"
    @test HeaderName(SubString("xHostx", 2, 5)) === header.HOST
    @test HeaderName(view(Vector{UInt8}("xHostx"), 2:5)) === header.HOST
    @test HeaderName(@view(Vector{UInt8}("hxoxsxtx")[1:2:8])) === header.HOST
    @test parse(HeaderName, "accept") === header.ACCEPT && tryparse(HeaderName, "a b") === nothing
    @test convert(HeaderName, "Vary") === header.VARY
    @test HttpTypes.standard_index(header.ACCEPT) == 1 && HttpTypes.standard_index(hn"x-foo") == 0
    @test all(HttpTypes.standard_header(HttpTypes.standard_index(getfield(header, k))) === getfield(header, k)
              for (k, _) in HttpTypes.STANDARD_HEADER_TABLE)
    @test length(HttpTypes.STANDARD_HEADER_TABLE) == 81
    @test string(header.ACCEPT) == "accept" && repr(header.ACCEPT) == "hn\"accept\""
    @test hash(HeaderName("X-A")) == hash(hn"x-a") && length(Set([hn"x-a", HeaderName("X-A")])) == 1
    @test_throws InvalidHeaderName HeaderName("bad name")
    @test_throws BoundsError HttpTypes.standard_header(0)
    @test_throws BoundsError HttpTypes.standard_header(82)
    # Equal under isequal means equal hashes: `==` crosses types, isequal does not.
    @test hn"x-a" == "X-A" && "x-a" == hn"x-a" && !isequal(hn"x-a", "x-a") && !isequal("x-a", hn"x-a")
    @test hv"v" == "v" && hv"v" == b"v" && !isequal(hv"v", "v") && !isequal("v", hv"v") && !isequal(hv"v", b"v")
    @test isequal(hn"x-a", HeaderName("X-A")) && isequal(hv"v", HeaderValue("v")) && hash(hv"v") == hash(HeaderValue("v"))
    @test !haskey(Dict{Any,Int}("x-a" => 1), hn"x-a") && !("v" in Set{Any}([hv"v"])) && hv"v" in Any["v"]
    @test length(unique(Any[hn"x-a", "x-a", hv"x-a"])) == 3
    @test sprint(showerror, InvalidHeaderName()) == "invalid HTTP header name"

    @test_throws InvalidHeaderValue HeaderValue("a\nb")
    @test_throws ToStrError to_str(HeaderValue(b"caf\xe9"))
    @test to_str(hv"text/plain") == "text/plain"
    @test string(HeaderValue("abc")) == "abc" && string(set_sensitive(hv"pw", true)) == "pw"
    @test HeaderValue(UInt16(8)) == "8" && convert(HeaderValue, 348) == "348"
    @test_throws MethodError HeaderValue(0x33)
    @test HttpTypes.unchecked(HeaderValue, "a\nb") == "a\nb"
    @test isempty(hv"") && length(hv"abc") == 3 && hv"a" < hv"b"
    s = "Content-Length"
    GC.@preserve s begin
        @test HeaderName(pointer(s), sizeof(s)) === header.CONTENT_LENGTH
        @test HeaderValue(pointer(s), 7) == "Content"
        @test HttpTypes.unchecked(HeaderValue, pointer(s), 7) == "Content"
    end

    e = entry(h, "x-new")
    @test e isa VacantEntry && key(e) == "X-New"
    @test or_insert!(e, "1") == "1"
    @test or_insert!(entry(h, "x-new"), "2") == "1"
    @test or_insert_with!(() -> "3", entry(h, "x-new")) == "1"
    @test or_insert_with!(() -> "3", entry(h, "x-other")) == "3"
    oe = insert_entry!(entry(h, "x-third"), "a")
    @test oe isa OccupiedEntry && oe[] == "a"
    append!(oe, "b")
    oe[] = "A"
    @test collect(oe) == ["A", "b"] && length(oe) == 2
    @test insert!(oe, "z") == "A" && collect(get_all(h, "x-third")) == ["z"]
    @test remove!(entry(h, "x-third")) == "z" && !haskey(h, "x-third")

    big = HeaderMap{Int}()
    for i in 1:24_576
        push!(big.names, HeaderName("h$i")); push!(big.values, i)
    end
    big.nkeys = 24_576
    @test_throws MaxSizeReached insert!(big, "one-more", 0)
    @test append!(big, "h1", 0) == true
    @test_throws MaxSizeReached reserve!(HeaderMap(), 24_577)
    @test reserve!(HeaderMap(), 24_576) isa HeaderMap
end

@testset "julia surface: uniform parse, convert and show" begin
    cases = (HttpMethod => ("GET", "G T"), StatusCode => ("404", "4x4"), HeaderName => ("Accept", "a b"),
        HeaderValue => ("v", "\0"), Scheme => ("ftp", "f/p"), Authority => ("h:80", "h/x"),
        PathAndQuery => ("/a?b", "a"), Port => ("+80", "70000"), Uri => ("/a?b", "a b"))
    for (T, (good, bad)) in cases
        want = T(good)
        b = Vector{UInt8}(good)
        @test T(b) == want && T(codeunits(good)) == want && T(view(b, 1:length(b))) == want
        @test GC.@preserve(b, T(pointer(b), length(b))) == want
        @test tryparse(T, good) == want && tryparse(T, b) == want
        @test GC.@preserve(b, tryparse(T, pointer(b), length(b))) == want
        @test convert(T, good) == want && convert(T, b) == want
        @test tryparse(T, bad) === nothing && tryparse(T, Vector{UInt8}(bad)) === nothing
        c = Vector{UInt8}(bad)
        @test GC.@preserve(c, tryparse(T, pointer(c), length(c))) === nothing
        @test_throws HttpError T(bad)
        @test_throws HttpError GC.@preserve(c, T(pointer(c), length(c)))
        @test_throws HttpError convert(T, bad)
        @test string(want) isa String
        @test eval(Meta.parse(repr(want))) == want
    end

    @test Port(8080) == 8080 && as_str(Port(8080)) == "8080" && Port(0) == 0 && Port(UInt16(65535)) == 65535
    @test_throws InvalidUri Port(65536)
    @test_throws InvalidUri Port(-1)
    @test tryparse(Port, 70000) === nothing && tryparse(Port, 443) == 443
    @test convert(Port, 80) == Port("80") && parse(Port, "81") == 81
    @test convert(StatusCode, 404) === StatusCodes.NOT_FOUND
    @test_throws InvalidStatusCode convert(StatusCode, 99)
    @test convert(Uri, Authority("h:1")) == Uri("h:1") && convert(Uri, PathAndQuery("/p")) == "/p"

    r = Request(; body="x")
    r.method = "PUT"; r.uri = codeunits("/a?b")
    @test method(r) === Methods.PUT && uri(r) == "/a?b"
    @test_throws InvalidMethod (r.method = "G T")
    @test_throws InvalidUri (r.uri = "a b")
    res = Response("x")
    res.status = 404
    @test status(res) === StatusCodes.NOT_FOUND
    res.status = "201"
    @test status(res) === StatusCodes.CREATED
    @test_throws InvalidStatusCode (res.status = 6666)

    shows = (Methods.GET => "Methods.GET", HttpMethod("PURGE") => "HttpMethod(\"PURGE\")",
        StatusCodes.NOT_FOUND => "StatusCodes.NOT_FOUND", StatusCode(599) => "StatusCode(599)",
        Versions.HTTP_11 => "Versions.HTTP_11", header.CONTENT_TYPE => "hn\"content-type\"",
        hv"text/plain" => "hv\"text/plain\"", Schemes.HTTPS => "Schemes.HTTPS",
        Authority("ex.com:80") => "Authority(\"ex.com:80\")", PathAndQuery("/a?b") => "PathAndQuery(\"/a?b\")",
        Port("+80") => "Port(80)", uri"http://ex.com/a?b" => "uri\"http://ex.com/a?b\"")
    for (x, s) in shows
        @test repr(x) == s
        @test eval(Meta.parse(s)) == x
    end
    @test string(uri"http://ex.com/a?b") == "http://ex.com/a?b" && string(Authority("ex.com")) == "ex.com"
    @test string(PathAndQuery("/a")) == "/a" && string(Port("+80")) == "80" && string(Scheme("ftp")) == "ftp"
end
