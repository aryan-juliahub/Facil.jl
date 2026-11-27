# Cookie parsing and set-cookie serialisation, alone and with curl's cookie jar.
module CookieTests

using Facil, Test, Dates

curl(args...) = read(ignorestatus(`curl -s --max-time 30 $(collect(args))`), String)
req_with(vals...) = Request(; headers = ["cookie" => v for v in vals])
sc(res) = String.(get_all(headers(res), "set-cookie"))
one(f) = only(sc(f(Response(StatusCodes.OK, ""))))

@testset "cookies" begin
    @testset "parsing" begin
        @test cookies(Request(; uri = "/")) == Dict{String,String}()
        @test cookies(req_with("a=1")) == Dict("a" => "1")
        @test cookies(req_with("a=1; b=2;c=3")) == Dict("a" => "1", "b" => "2", "c" => "3")
        @test cookies(req_with("  a = 1 ;\tb=2\t;  ")) == Dict("a" => "1", "b" => "2")
        @test cookies(req_with("a=\"quoted\"; b=\"; c=\"\"")) == Dict("a" => "quoted", "b" => "\"", "c" => "")
        @test cookies(req_with("a=1; a=2")) == Dict("a" => "1")
        @test cookies(req_with("a=1", "a=2; b=3")) == Dict("a" => "1", "b" => "3")
        @test cookies(req_with("novalue; =x; ;;; ok=1")) == Dict("ok" => "1")
        @test cookies(req_with("e=")) == Dict("e" => "")
        @test cookies(req_with("t=a=b=c")) == Dict("t" => "a=b=c")
        @test cookies(req_with("x=%20%zz")) == Dict("x" => "%20%zz")
        @test cookies(req_with("x=%20%zz"); unescape = true) == Dict("x" => " %zz")
        @test cookies(Request(; headers = ["cookie" => HeaderValue(Vector{UInt8}("ü=é"))])) == Dict("ü" => "é")
    end

    @testset "set_cookie! serialisation" begin
        @test one(r -> set_cookie!(r, "a", "1")) == "a=1"
        @test one(r -> set_cookie!(r, "a", "")) == "a="
        @test one(r -> set_cookie!(r, "a", "\"q\"")) == "a=\"q\""
        @test one(r -> set_cookie!(r, "sid", "x"; path = "/", domain = "example.com", max_age = 60,
                                   expires = DateTime(2026, 1, 2, 3, 4, 5), secure = true, http_only = true,
                                   same_site = :strict, partitioned = true)) ==
              "sid=x; Path=/; Domain=example.com; Max-Age=60; Expires=Fri, 02 Jan 2026 03:04:05 GMT; Secure; HttpOnly; SameSite=Strict; Partitioned"
        @test one(r -> set_cookie!(r, "a", "1"; max_age = Day(1))) == "a=1; Max-Age=86400"
        @test one(r -> set_cookie!(r, "a", "1"; same_site = :lax)) == "a=1; SameSite=Lax"
        @test one(r -> set_cookie!(r, "a", "1"; same_site = :none, secure = true)) == "a=1; Secure; SameSite=None"
        @test one(r -> set_cookie!(r, "a", "x y;z"; escape = true)) == "a=x%20y%3Bz"
        @test one(r -> set_cookie!(r, "__Host-id", "1"; secure = true, path = "/")) == "__Host-id=1; Path=/; Secure"
        @test one(r -> set_cookie!(r, "__Secure-id", "1"; secure = true)) == "__Secure-id=1; Secure"
        @test one(r -> delete_cookie!(r, "sid"; path = "/")) == "sid=; Path=/; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT"
        @test one(r -> delete_cookie!(r, "__Host-s"; path = "/", secure = true)) ==
              "__Host-s=; Path=/; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Secure"
        res = Response(StatusCodes.OK, "")
        @test set_cookie!(res, "a", "1") === res
        set_cookie!(res, "b", "2")
        @test sc(res) == ["a=1", "b=2"]
    end

    @testset "validation" begin
        r = Response(StatusCodes.OK, "")
        for bad in ("", "a b", "a;b", "a=b", "a,b", "é", "a\tb", "(x)")
            @test_throws ArgumentError set_cookie!(r, bad, "v")
        end
        for bad in ("a b", "a;b", "a,b", "a\\b", "a\"b", "é", "a\nb", "\"x")
            @test_throws ArgumentError set_cookie!(r, "n", bad)
        end
        @test_throws ArgumentError set_cookie!(r, "n", "v"; path = "/a;b")
        @test_throws ArgumentError set_cookie!(r, "n", "v"; domain = "a\r\nb")
        @test_throws ArgumentError set_cookie!(r, "n", "v"; same_site = :none)
        @test_throws ArgumentError set_cookie!(r, "n", "v"; same_site = :bogus, secure = true)
        @test_throws ArgumentError set_cookie!(r, "n", "v"; partitioned = true)
        @test_throws ArgumentError set_cookie!(r, "__Secure-n", "v")
        @test_throws ArgumentError set_cookie!(r, "__Host-n", "v"; secure = true)
        @test_throws ArgumentError set_cookie!(r, "__Host-n", "v"; secure = true, path = "/", domain = "a.com")
        @test isempty(sc(r))
    end

    @testset "curl cookie jar" begin
        srv = serve!("127.0.0.1", 0) do req
            p = path(uri(req))
            res = Response(StatusCodes.OK, "")
            if p == "/login"
                set_cookie!(res, "sid", "abc123"; path = "/", http_only = true)
                set_cookie!(res, "note", "hello world; ok"; path = "/", escape = true)
                set_cookie!(res, "gone", "1"; path = "/")
            elseif p == "/logout"
                delete_cookie!(res, "gone"; path = "/")
            else
                c = cookies(req; unescape = true)
                res = Response(StatusCodes.OK, join(sort!(["$k=$v" for (k, v) in c]), "\n"))
            end
            res
        end
        try
            base = "http://127.0.0.1:$(port(srv))"
            jar = tempname()
            @test curl("-c", jar, "$base/login") == ""
            @test curl("-b", jar, "$base/whoami") == "gone=1\nnote=hello world; ok\nsid=abc123"
            curl("-b", jar, "-c", jar, "$base/logout")
            @test curl("-b", jar, "$base/whoami") == "note=hello world; ok\nsid=abc123"
            @test curl("-H", "Cookie: a=1; a=2", "-H", "Cookie: b=\"x\"", "$base/") == "a=1\nb=x"
            rm(jar; force = true)
        finally
            close(srv)
        end
    end
end

end
