# Percent-decoding, query and form parsing, and decoded paths, alone and through a server.
module URLTests

using Facil, Test

curl(args...) = read(ignorestatus(`curl -s --max-time 30 $(collect(args))`), String)

@testset "url" begin
    @testset "no clash with URIs.jl exports" begin
        uris = (:URI, :absuri, :escapepath, :escapeuri, :queryparampairs, :queryparams, :resolvereference, :splitfilepath, :unescapeuri)
        @test isempty(intersect(names(Facil), uris))
    end

    @testset "percent_decode" begin
        @test percent_decode("") == ""
        @test percent_decode("plain") == "plain"
        @test percent_decode("caf%C3%A9") == "café"
        @test percent_decode("caf%c3%a9") == "café"
        @test percent_decode("a+b") == "a+b"
        @test percent_decode("a+b%2B"; plus = true) == "a b+"
        @test percent_decode("%zz%4%") == "%zz%4%"
        @test percent_decode("100%25") == "100%"
        @test percent_decode("%FF") == "�"
        @test percent_decode("a%C3") == "a�"
        @test isvalid(percent_decode("%80%E2%82"))
        @test percent_decode("%2F%00") == "/\0"
        @test percent_decode(SubString("xx%41yy", 3, 5)) == "A"
        @test percent_decode(SubString("é%41", 1)) == "éA"
    end

    @testset "percent_encode" begin
        @test percent_encode("") == ""
        @test percent_encode("AZaz09-._~") == "AZaz09-._~"
        @test percent_encode("a b&c=d/e?f#g+h%") == "a%20b%26c%3Dd%2Fe%3Ff%23g%2Bh%25"
        @test percent_encode("café") == "caf%C3%A9"
        for s in ("", "x", "a b+c", "ünï©ødé ✓", String(rand(UInt8(0x20):UInt8(0x7e), 50)))
            @test percent_decode(percent_encode(s)) == s
            @test parse_query("k=" * percent_encode(s)) == ["k" => s]
        end
    end

    @testset "parse_query" begin
        @test parse_query("") == Pair{String,String}[]
        @test parse_query("?") == Pair{String,String}[]
        @test parse_query("a=1") == ["a" => "1"]
        @test parse_query("?a=1") == ["a" => "1"]
        @test parse_query("a=1&b=2&a=3") == ["a" => "1", "b" => "2", "a" => "3"]
        @test parse_query("a&b=&=c&&d=e=f") == ["a" => "", "b" => "", "" => "c", "d" => "e=f"]
        @test parse_query("&&a=1&&") == ["a" => "1"]
        @test parse_query("q=caf%C3%A9+au+lait") == ["q" => "café au lait"]
        @test parse_query("a%20b+c=d%26e") == ["a b c" => "d&e"]
        @test parse_query("x=%zz&y=%FF") == ["x" => "%zz", "y" => "�"]
        @test parse_query("a=1;b=2") == ["a" => "1;b=2"]
        @test parse_query("é=ü") == ["é" => "ü"]
        @test parse_query(SubString("??a=1", 2)) == ["a" => "1"]
    end

    @testset "parse_form" begin
        @test parse_form("user=ada&note=hi+there%21") == ["user" => "ada", "note" => "hi there!"]
        @test parse_form("?a=1") == ["?a" => "1"]
        b = Vector{UInt8}("a=1&a=2")
        @test parse_form(b) == ["a" => "1", "a" => "2"]
        @test b == Vector{UInt8}("a=1&a=2")
        @test parse_form(Request(; method = "POST", uri = "/", body = "x=%20")) == ["x" => " "]
        @test parse_form(Request(; method = "POST", uri = "/", body = "")) == Pair{String,String}[]
    end

    @testset "request accessors" begin
        r = Request(; uri = "/s?q=julia+web&tag=a&tag=b&e=")
        @test query_params(r) == ["q" => "julia web", "tag" => "a", "tag" => "b", "e" => ""]
        @test query_param(r, "tag") == "a"
        @test query_param(r, "e") == ""
        @test query_param(r, "none") === nothing
        @test query_param(r, "none"; default = "d") == "d"
        @test query_param(Request(; uri = "/s?a%20b=1"), "a b") == "1"
        @test query_params(Request(; uri = "/s")) == Pair{String,String}[]
        @test query_param(Request(; uri = "/s"), "q"; default = 0) == 0
        @test query_params(Request(; uri = "/s?")) == Pair{String,String}[]
    end

    @testset "decoded_path" begin
        dp(t) = decoded_path(Request(; uri = t))
        @test dp("/") == "/"
        @test dp("/a/b") == "/a/b"
        @test dp("/caf%C3%A9/a+b") == "/café/a+b"
        @test dp("/a%20b") == "/a b"
        @test dp("/%2E%2E/x") == "/../x"
        @test dp("/a%2Fb") === nothing
        @test dp("/a%2fb") === nothing
        @test dp("/a%00") === nothing
        @test dp("/a%zz") === nothing
        @test dp("/a%4") === nothing
        @test dp("/a%") === nothing
        @test dp("/a%FF") === nothing
        @test dp("/a%C3") === nothing
        @test dp("/x?q=%2F") == "/x"
    end

    @testset "through a server" begin
        srv = serve!("127.0.0.1", 0) do req
            p = decoded_path(req)
            p === nothing && return Response(StatusCodes.BAD_REQUEST, "bad path\n")
            p == "/form" && return Response(StatusCodes.OK, repr(parse_form(req)))
            Response(StatusCodes.OK, string(p, "|", repr(query_params(req)), "|", repr(query_param(req, "n"; default = "1"))))
        end
        try
            base = "http://127.0.0.1:$(port(srv))"
            @test curl("$base/caf%C3%A9?name=Ada+L&tag=a&tag=b") ==
                  "/café|[\"name\" => \"Ada L\", \"tag\" => \"a\", \"tag\" => \"b\"]|\"1\""
            @test curl("$base/x?n=5") == "/x|[\"n\" => \"5\"]|\"5\""
            @test curl("$base/a%2Fb") == "bad path\n"
            @test curl("$base/form", "--data-urlencode", "msg=hello world & more", "--data-urlencode", "e=é") ==
                  repr(["msg" => "hello world & more", "e" => "é"])
        finally
            close(srv)
        end
    end
end

end
