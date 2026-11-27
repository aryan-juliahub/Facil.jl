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


const CACHE_PORTS = 4110:4119

# Unix time `t` as an HTTP-date: IMF-fixdate, or the obsolete RFC 850 and asctime forms.
function httpdate(t::Integer; form = :imf)
    days, secs = fldmod(t, 86400)
    z = days + 719468
    era = fld(z, 146097)
    doe = z - era * 146097
    yoe = (doe - doe ÷ 1460 + doe ÷ 36524 - doe ÷ 146096) ÷ 365
    doy = doe - (365yoe + yoe ÷ 4 - yoe ÷ 100)
    mp = (5doy + 2) ÷ 153
    d = doy - (153mp + 2) ÷ 5 + 1
    m = mp < 10 ? mp + 3 : mp - 9
    y = yoe + era * 400 + (m <= 2)
    wd = mod(days + 4, 7) + 1
    short = ("Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat")[wd]
    long = ("Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday")[wd]
    mon = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")[m]
    clock = join(lpad.((secs ÷ 3600, secs % 3600 ÷ 60, secs % 60), 2, '0'), ':')
    form === :imf && return "$short, $(lpad(d, 2, '0')) $mon $y $clock GMT"
    form === :rfc850 && return "$long, $(lpad(d, 2, '0'))-$mon-$(lpad(y % 100, 2, '0')) $clock GMT"
    "$short $mon $(lpad(d, 2)) $clock $y"
end

@testset "static: cache-control, If-Modified-Since, directories, dotfiles" begin
    dir = mktempdir()
    write(joinpath(dir, "a.txt"), "AAA")
    mkpath(joinpath(dir, "docs"))
    write(joinpath(dir, "docs", "index.html"), "<p>docs</p>")
    mkpath(joinpath(dir, "empty"))
    write(joinpath(dir, ".env"), "KEY=1")
    mkpath(joinpath(dir, ".well-known"))
    write(joinpath(dir, ".well-known", "security.txt"), "Contact: x")
    mkpath(joinpath(dir, ".git"))
    write(joinpath(dir, ".git", "config"), "cfg")
    handler(req) = Response(200, "handler " * path(uri(req)))

    srv = serve!(handler, CACHE_PORTS[1]; public_folder = dir)
    try
        p = port(srv)
        r = get1(p, "/a.txt")
        @test r.status == 200 && r["cache-control"] == "max-age=3600"
        lm = r["last-modified"]
        mtime = floor(Int, Base.Filesystem.mtime(joinpath(dir, "a.txt")))
        @test lm == httpdate(mtime)

        # If-Modified-Since: not newer gives 304, newer gives the file
        @test get1(p, "/a.txt"; headers = ["If-Modified-Since" => lm]).status == 304
        r = get1(p, "/a.txt"; headers = ["If-Modified-Since" => httpdate(mtime + 60)])
        @test r.status == 304 && isempty(r.body) && haskey(r, "etag")
        r = get1(p, "/a.txt"; headers = ["If-Modified-Since" => httpdate(mtime - 60)])
        @test r.status == 200 && String(r.body) == "AAA"
        @test get1(p, "/a.txt"; method = "HEAD", headers = ["If-Modified-Since" => lm]).status == 304
        # the two obsolete date forms
        @test get1(p, "/a.txt"; headers = ["If-Modified-Since" => httpdate(mtime + 60; form = :rfc850)]).status == 304
        @test get1(p, "/a.txt"; headers = ["If-Modified-Since" => httpdate(mtime + 60; form = :asctime)]).status == 304
        @test get1(p, "/a.txt"; headers = ["If-Modified-Since" => httpdate(mtime - 60; form = :asctime)]).status == 200
        # an invalid date is ignored
        @test get1(p, "/a.txt"; headers = ["If-Modified-Since" => "yesterday"]).status == 200
        # If-None-Match wins: a stale tag with a fresh date still sends the file
        r = get1(p, "/a.txt"; headers = ["If-None-Match" => "\"stale\"", "If-Modified-Since" => httpdate(mtime + 60)])
        @test r.status == 200 && String(r.body) == "AAA"
        etag = get1(p, "/a.txt")["etag"]
        @test get1(p, "/a.txt"; headers = ["If-None-Match" => etag, "If-Modified-Since" => httpdate(mtime - 60)]).status == 304

        # a directory without its slash: 301 to the slash, query kept, when it has an index
        r = get1(p, "/docs")
        @test r.status == 301 && r["location"] == "/docs/"
        r = get1(p, "/docs?a=1&b=2")
        @test r.status == 301 && r["location"] == "/docs/?a=1&b=2"
        @test get1(p, "/docs"; method = "HEAD").status == 301
        @test String(get1(p, "/docs/").body) == "<p>docs</p>"
        @test String(get1(p, "/empty").body) == "handler /empty"
        @test String(get1(p, "/docs"; method = "POST", body = "x").body) == "handler /docs"

        # dotfiles are denied by default, .well-known is not
        @test String(get1(p, "/.env").body) == "handler /.env"
        @test String(get1(p, "/.git/config").body) == "handler /.git/config"
        @test String(get1(p, "/%2eenv").body) == "handler /%2eenv"
        @test String(get1(p, "/.well-known/security.txt").body) == "Contact: x"
        @test String(get1(p, "/.well-knownx/security.txt").body) == "handler /.well-knownx/security.txt"
    finally
        close(srv); wait(srv)
    end

    srv = serve!(handler, CACHE_PORTS[2]; public_folder = dir, dotfiles = :serve,
                 static_cache_control = "public, max-age=31536000, immutable")
    try
        p = port(srv)
        r = get1(p, "/a.txt")
        @test r["cache-control"] == "public, max-age=31536000, immutable"
        @test String(get1(p, "/.env").body) == "KEY=1"
        # sendfile responses keep the default
        @test String(get1(p, "/x").body) == "handler /x"
    finally
        close(srv); wait(srv)
    end

    srv = serve!(handler, CACHE_PORTS[3]; public_folder = dir, static_cache_control = nothing)
    try
        r = get1(port(srv), "/a.txt")
        @test r.status == 200 && !haskey(r, "cache-control")
    finally
        close(srv); wait(srv)
    end

    @test_throws ArgumentError serve!(handler, CACHE_PORTS[4]; static_cache_control = "no-cache")
    @test_throws ArgumentError serve!(handler, CACHE_PORTS[4]; dotfiles = :serve)
    @test_throws ArgumentError serve!(handler, CACHE_PORTS[4]; public_folder = dir, static_cache_control = "a\r\nb: c")
    @test_throws ArgumentError serve!(handler, CACHE_PORTS[4]; public_folder = dir, static_cache_control = "")
    @test_throws ArgumentError serve!(handler, CACHE_PORTS[4]; public_folder = dir, static_cache_control = 3600)
end

end
