# Static files: public_folder and sendfile, with content types, validators,
# conditional and range requests, HEAD, gzip siblings and the handler fallback.
module M6StaticTests

using Facil, Test, Sockets
isdefined(Main, :M6Http) || Main.include(joinpath(@__DIR__, "m6_http.jl"))
using Main.M6Http
import Main.M6Http

const STATIC_PORTS = 3775:3784

function static_tree()
    d = mktempdir()
    write(joinpath(d, "index.html"), "<h1>home</h1>")
    write(joinpath(d, "app.js"), "console.log(1)")
    write(joinpath(d, "style.css"), "body{}")
    write(joinpath(d, "data.json"), "{\"a\":1}")
    write(joinpath(d, "pic.webp"), UInt8[0x52, 0x49, 0x46, 0x46])
    write(joinpath(d, "blob.m6bin"), rand(UInt8, 3000))
    write(joinpath(d, "with space.txt"), "spaced")
    write(joinpath(d, "range.txt"), "0123456789abcdefghij")
    write(joinpath(d, "zipped.txt"), "plain text version")
    write(joinpath(d, "zipped.txt.gz"), Facil.gzip("plain text version"))
    mkpath(joinpath(d, "sub"))
    write(joinpath(d, "sub", "index.html"), "<p>sub</p>")
    outside = mktempdir()
    write(joinpath(outside, "secret.txt"), "secret")
    d, outside
end

@testset "static" begin
    @testset "MIME table" begin
        @test Facil.mime_type("a/b/index.html") == "text/html; charset=utf-8"
        @test Facil.mime_type("x.JS") == "text/javascript; charset=utf-8"
        @test Facil.mime_type("x.json") == "application/json"
        @test Facil.mime_type("x.wasm") == "application/wasm"
        @test Facil.mime_type("x.woff2") == "font/woff2"
        @test Facil.mime_type("x.unknownext") == "application/octet-stream"
        @test Facil.mime_type("noext") == "application/octet-stream"
        Facil.register_mime!(".m6test", "application/x-m6")
        @test Facil.mime_type("f.m6test") == "application/x-m6"
        @test_throws ArgumentError Facil.register_mime!("", "x/y")
    end

    dir, outside = static_tree()
    secret_rel = relpath(joinpath(outside, "secret.txt"), dir)
    handled = Threads.Atomic{Int}(0)
    app = function (req)
        Threads.atomic_add!(handled, 1)
        p = path(uri(req))
        if p == "/file"
            return sendfile(req, joinpath(dir, "app.js"); headers = ["x-file" => "1"])
        elseif p == "/file/blob"
            return sendfile(joinpath(dir, "blob.m6bin"))
        elseif p == "/file/missing"
            return sendfile(joinpath(dir, "nope.txt"))
        elseif p == "/file/zipped"
            return sendfile(joinpath(dir, "zipped.txt"))
        elseif p == "/file/created"
            return sendfile(joinpath(dir, "data.json"); status = StatusCodes.CREATED)
        end
        Response(StatusCodes.OK, "handler " * string(method(req)) * " " * p)
    end

    for inline in (true, false)
        srv = serve!(app, STATIC_PORTS[1 + inline]; inline, public_folder = dir)
        port = Facil.port(srv)
        try
            r = get1(port, "/app.js")
            @test r.status == 200
            @test r["content-type"] == "text/javascript; charset=utf-8"
            @test String(r.body) == "console.log(1)"
            @test r["content-length"] == "14"
            @test haskey(r, "etag") && haskey(r, "last-modified")
            @test r["accept-ranges"] == "bytes"
            etag = r["etag"]

            @test get1(port, "/style.css")["content-type"] == "text/css; charset=utf-8"
            @test get1(port, "/data.json")["content-type"] == "application/json"
            @test get1(port, "/pic.webp")["content-type"] == "image/webp"
            @test String(get1(port, "/").body) == "<h1>home</h1>"
            @test String(get1(port, "/sub/").body) == "<p>sub</p>"
            @test String(get1(port, "/with%20space.txt").body) == "spaced"

            # conditional and range requests
            r = get1(port, "/app.js"; headers = ["If-None-Match" => etag])
            @test r.status == 304 && isempty(r.body)
            r = get1(port, "/app.js"; headers = ["If-None-Match" => "\"other\", $etag"])
            @test r.status == 304
            r = get1(port, "/range.txt"; headers = ["Range" => "bytes=2-5"])
            @test r.status == 206 && String(r.body) == "2345"
            @test r["content-range"] == "bytes 2-5/20"
            r = get1(port, "/range.txt"; headers = ["Range" => "bytes=-3"])
            @test r.status == 206 && String(r.body) == "hij"
            r = get1(port, "/range.txt"; headers = ["Range" => "bytes=50-60"])
            @test r.status == 416
            r = get1(port, "/range.txt"; headers = ["Range" => "bytes=2-5", "If-Range" => "\"stale\""])
            @test r.status == 200 && length(r.body) == 20

            # HEAD and OPTIONS
            r = get1(port, "/app.js"; method = "HEAD")
            @test r.status == 200 && isempty(r.body) && r["content-length"] == "14"
            @test r["content-type"] == "text/javascript; charset=utf-8"

            # a gzip sibling for clients that accept gzip
            r = get1(port, "/zipped.txt"; headers = ["Accept-Encoding" => "gzip"])
            @test r["content-encoding"] == "gzip"
            @test String(Facil.gunzip(r.body)) == "plain text version"
            @test String(get1(port, "/zipped.txt").body) == "plain text version"

            # anything that is not a file reaches the handler, and so do other methods
            h0 = handled[]
            @test String(get1(port, "/nothing-here").body) == "handler GET /nothing-here"
            r = get1(port, "/app.js"; method = "POST", body = "x=1")
            @test r.status == 200 && String(r.body) == "handler POST /app.js"
            @test String(get1(port, "/app.js"; method = "DELETE").body) == "handler DELETE /app.js"
            @test handled[] == h0 + 3
            # no escape from the folder
            for p in ("/" * secret_rel, "/" * replace(secret_rel, "/" => "%2f"), "/sub/../" * secret_rel)
                @test startswith(String(get1(port, p).body), "handler")
            end

            # sendfile responses
            r = get1(port, "/file")
            @test r.status == 200 && String(r.body) == "console.log(1)"
            @test r["content-type"] == "text/javascript; charset=utf-8"
            @test r["x-file"] == "1"
            @test get1(port, "/file"; headers = ["If-None-Match" => etag]).status == 304
            r = get1(port, "/file"; method = "HEAD")
            @test r.status == 200 && r["content-length"] == "14"
            r = get1(port, "/file/blob")
            @test r.body == read(joinpath(dir, "blob.m6bin"))
            @test r["content-type"] == "application/octet-stream"
            @test get1(port, "/file/missing").status == 404
            r = get1(port, "/file"; method = "POST", body = "a")
            @test r.status == 405 && r["allow"] == "GET, HEAD, OPTIONS"
            r = get1(port, "/file/created")
            @test r.status == 201 && String(r.body) == "{\"a\":1}"
            r = get1(port, "/file/zipped"; headers = ["Accept-Encoding" => "gzip, br"])
            @test r["content-encoding"] == "gzip"

            # keep-alive across static, sendfile and handler replies
            s, t = rawconn(port)
            for p in ("/app.js", "/file", "/x", "/range.txt")
                send_raw(s, request("GET", p))
                @test read_response(s).status == 200
            end
            close(t); close(s)
        finally
            close(srv); wait(srv)
        end
    end

    @test_throws ArgumentError serve!(app, STATIC_PORTS[3]; public_folder = joinpath(dir, "missing-dir"))
    @test_throws ArgumentError sendfile("a\0b")
end

end
