# HTTPS: certificates, protocol settings, SNI, client certificates, reload!,
# large bodies and task handlers over TLS. Ports 3850-3879. Certificates in
# test/certs (throwaway, regenerate with make.sh); client in test/tls/client.js.

module TLSTests

using Facil, Test
import Downloads
const F = Facil

const PORTS = 3850:3879
const TAKEN = Set{Int}()
listening(p) = !isempty(readchomp(ignorestatus(`lsof -nP -t -iTCP:$p -sTCP:LISTEN`)))
function free_port()
    for p in PORTS
        (p in TAKEN || listening(p)) && continue
        push!(TAKEN, p)
        return p
    end
    error("no free port in $PORTS")
end

const NODE = something(Sys.which("node"), "node")
const CLIENT = joinpath(@__DIR__, "tls", "client.js")
const CERTS = joinpath(@__DIR__, "certs")
cert(name) = joinpath(CERTS, name * "_cert.pem")
key(name) = joinpath(CERTS, name * "_key.pem")

json(x::AbstractString) = repr(String(x))
json(x::Union{Integer,Bool}) = string(x)
json(x::AbstractVector) = "[" * join(json.(x), ",") * "]"
json(x::AbstractDict) = "{" * join((json(string(k)) * ":" * json(v) for (k, v) in x), ",") * "}"

# One Dict per request: status, len, intact, clen, socket, protocol, cipher, alpn, cn, org, body (or error).
function hget(port, requests; tls = Dict(), servername = nothing, keepalive = false, parallel = false)
    spec = Dict{String,Any}("port" => port, "tls" => tls, "requests" => requests,
                            "keepalive" => keepalive, "parallel" => parallel)
    servername === nothing || (spec["servername"] = servername)
    out = readchomp(`$NODE $CLIENT $(json(spec))`)
    [Dict(String(a) => String(b) for (a, b) in (split(f, '='; limit = 2) for f in split(l, '\t'))) for l in split(out, '\n')]
end
function wsecho(port; count, size)
    spec = Dict{String,Any}("port" => port, "ws" => Dict("path" => "/ws", "count" => count, "size" => size))
    l = readchomp(`$NODE $CLIENT $(json(spec))`)
    Dict(String(a) => String(b) for (a, b) in (split(f, '='; limit = 2) for f in split(l, '\t')))
end
get1(port, path = "/hello"; kw...) = only(hget(port, [Dict("path" => path)]; kw...))

function pattern(n)
    v = Vector{UInt8}(undef, n)
    @inbounds for i in 0:n-1
        v[i+1] = ((i * 7 + (i >>> 10)) & 0xff) % UInt8
    end
    v
end
const PATTERNS = Dict{Int,Vector{UInt8}}()
const PLOCK = ReentrantLock()
cached_pattern(n) = lock(() -> get!(() -> pattern(n), PATTERNS, n), PLOCK)

function app(req)
    p = path(uri(req))
    if p == "/hello"
        "hello"
    elseif p == "/echo"
        Response(StatusCodes.OK, Vector{UInt8}(codeunits(body(req))))
    elseif startswith(p, "/bytes/")
        Response(StatusCodes.OK, cached_pattern(parse(Int, p[8:end])))
    elseif startswith(p, "/stream/")
        n = parse(Int, p[9:end])
        src = cached_pattern(n)
        stream(req) do io
            for (k, i) in enumerate(1:65536:n)
                write(io, src[i:min(i + 65535, n)])
                k % 8 == 0 && Facil.sleep(0.001)
            end
        end
    elseif p == "/ws"
        websocket(req; on_message = (ws, msg) -> Threads.@spawn send(ws, msg))
    elseif startswith(p, "/slow/")
        Facil.sleep(0.01)
        Response(StatusCodes.OK, cached_pattern(parse(Int, p[7:end])))
    else
        Response(StatusCodes.NOT_FOUND)
    end
end

function withserver(f, cfg; kw...)
    p = free_port()
    s = serve!(app, p; tls = cfg, kw...)
    try
        f(p, s)
    finally
        close(s)
        wait(s)
    end
end

ok(r) = !haskey(r, "error") && r["status"] == "200"
refused(r) = haskey(r, "error")

function main()
    @testset "TLSConfig" begin
        c = TLSConfig(cert("rsa"), key("rsa"))
        @test sprint(show, c) == "TLSConfig(1 certificate(s), TLS 1.2+)"
        @test TLSConfig(read(cert("rsa"), String), read(key("rsa"), String)) isa TLSConfig
        @test_throws ArgumentError TLSConfig(joinpath(CERTS, "missing.pem"), key("rsa"))
        @test_throws ArgumentError TLSConfig(joinpath(CERTS, "make.sh"), key("rsa"))
        e = try TLSConfig(cert("rsa"), key("ec")) catch e; e end
        @test e isa TLSError && occursin("does not match", sprint(showerror, e))
        @test_throws TLSError TLSConfig(cert("rsa"), cert("rsa"))
        @test_throws TLSError TLSConfig(key("rsa"), key("rsa"))
        e = try TLSConfig(cert("rsa"), joinpath(CERTS, "rsa_key_enc.pem")) catch e; e end
        @test e isa TLSError && occursin("password", sprint(showerror, e))
        @test_throws TLSError TLSConfig(cert("rsa"), joinpath(CERTS, "rsa_key_enc.pem"); password = "wrong")
        @test TLSConfig(cert("rsa"), joinpath(CERTS, "rsa_key_enc.pem"); password = "secret") isa TLSConfig
        @test_throws TLSError TLSConfig(cert("rsa"), key("rsa"); ciphers = "NO-SUCH-CIPHER")
        @test_throws TLSError TLSConfig(cert("rsa"), key("rsa"); ciphersuites = "TLS_NO_SUCH")
        @test_throws ArgumentError TLSConfig(cert("rsa"), key("rsa"); min_version = v"2.0")
        @test_throws ArgumentError TLSConfig(cert("rsa"), key("rsa"); min_version = v"1.3", max_version = v"1.2")
        @test_throws ArgumentError TLSConfig(cert("rsa"), key("rsa"); require_client_cert = true)
        @test_throws ArgumentError TLSConfig(cert("rsa"), key("rsa"); sni = [("a.test", cert("a"))])
        @test_throws TLSError TLSConfig(cert("rsa"), key("rsa"); sni = [("a.test", cert("a"), key("b"))])
        @test_throws TLSError TLSConfig(cert("rsa"), key("rsa"); client_ca = key("ca"))
        p = free_port()
        @test_throws ArgumentError serve!(app, p; tls = TLSConfig(cert("rsa"), key("rsa")), reactors = 2)
        @test_throws ArgumentError serve!(app, p; tls = "yes")
        @test !listening(p)
    end

    @testset "HTTPS requests, RSA" begin
        withserver(TLSConfig(cert("rsa"), key("rsa"))) do p, s
            @test F.is_tls(s)
            r = get1(p; tls = Dict("ca" => cert("rsa")))
            @test ok(r) && r["body"] == "hello" && r["protocol"] in ("TLSv1.3", "TLSv1.2")
            r = get1(p; tls = Dict("ALPNProtocols" => ["h2", "http/1.1"]))
            @test ok(r) && r["alpn"] == "http/1.1"
            r = only(hget(p, [Dict("method" => "HEAD", "path" => "/bytes/5000")]))
            @test r["status"] == "200" && r["len"] == "0" && r["clen"] == "5000"
            sizes = [1, 1024, 16383, 16384, 16385, 100_000, 1 << 20, 8 << 20]
            rs = hget(p, [Dict("path" => "/bytes/$n", "expect" => n) for n in sizes]; keepalive = true)
            @test all(r -> ok(r) && r["intact"] == "true", rs)
            @test all(r -> r["socket"] == "0", rs)
            rs = hget(p, [Dict("method" => "POST", "path" => "/echo", "size" => n) for n in sizes]; keepalive = true)
            @test all(r -> ok(r) && r["intact"] == "true", rs)
            @test [parse(Int, r["len"]) for r in rs] == sizes
            r = get1(p; tls = Dict("maxVersion" => "TLSv1.2"))
            @test ok(r) && r["protocol"] == "TLSv1.2" && occursin("RSA", r["cipher"])
            @test get1(p, "/nope")["status"] == "404"
        end
    end

    @testset "ECDSA certificate" begin
        withserver(TLSConfig(cert("ec"), key("ec"))) do p, s
            r = get1(p; tls = Dict("ca" => cert("ec"), "maxVersion" => "TLSv1.2"))
            @test ok(r) && occursin("ECDSA", r["cipher"])
            @test ok(get1(p; tls = Dict("ca" => cert("ec"))))
        end
    end

    @testset "SNI" begin
        cfg = TLSConfig(cert("rsa"), key("rsa"); sni = [("a.test", cert("a"), key("a")), ("*.b.test", cert("b"), key("b"))])
        @test sprint(show, cfg) == "TLSConfig(3 certificate(s), TLS 1.2+)"
        withserver(cfg) do p, s
            @test get1(p; servername = "a.test")["cn"] == "a.test"
            @test get1(p; servername = "www.b.test")["cn"] == "b.test"
            @test get1(p; servername = "other.test")["cn"] == "localhost"
            @test get1(p)["cn"] == "localhost"
        end
    end

    @testset "password-protected key" begin
        withserver(TLSConfig(cert("rsa"), joinpath(CERTS, "rsa_key_enc.pem"); password = "secret")) do p, s
            @test ok(get1(p; tls = Dict("ca" => cert("rsa"))))
        end
    end

    @testset "protocol versions and ciphers" begin
        withserver(TLSConfig(cert("rsa"), key("rsa"))) do p, s
            old = Dict("minVersion" => "TLSv1.1", "maxVersion" => "TLSv1.1", "ciphers" => "DEFAULT@SECLEVEL=0")
            @test refused(get1(p; tls = old))
            @test ok(get1(p; tls = Dict("maxVersion" => "TLSv1.2")))
        end
        withserver(TLSConfig(cert("rsa"), key("rsa"); min_version = v"1.3")) do p, s
            @test refused(get1(p; tls = Dict("maxVersion" => "TLSv1.2")))
            @test get1(p)["protocol"] == "TLSv1.3"
        end
        withserver(TLSConfig(cert("rsa"), key("rsa"); max_version = v"1.2", ciphers = "ECDHE-RSA-AES128-GCM-SHA256")) do p, s
            r = get1(p)
            @test ok(r) && r["protocol"] == "TLSv1.2" && r["cipher"] == "ECDHE-RSA-AES128-GCM-SHA256"
        end
        withserver(TLSConfig(cert("rsa"), key("rsa"); ciphersuites = "TLS_CHACHA20_POLY1305_SHA256")) do p, s
            @test get1(p)["cipher"] == "TLS_CHACHA20_POLY1305_SHA256"
        end
        offer = "TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256"
        withserver(TLSConfig(cert("rsa"), key("rsa"); ciphersuites = "TLS_AES_128_GCM_SHA256:TLS_CHACHA20_POLY1305_SHA256",
                             prefer_server_ciphers = true)) do p, s
            @test get1(p; tls = Dict("ciphers" => offer))["cipher"] == "TLS_AES_128_GCM_SHA256"
        end
    end

    @testset "client certificates" begin
        client = Dict("cert" => cert("client"), "key" => key("client"))
        stranger = Dict("cert" => cert("stranger"), "key" => key("stranger"))
        withserver(TLSConfig(cert("rsa"), key("rsa"); client_ca = cert("ca"), require_client_cert = true)) do p, s
            @test refused(get1(p))
            @test ok(get1(p; tls = client))
            @test refused(get1(p; tls = stranger))
        end
        withserver(TLSConfig(cert("rsa"), key("rsa"); client_ca = cert("ca"))) do p, s
            @test ok(get1(p))
            @test ok(get1(p; tls = client))
            @test refused(get1(p; tls = stranger))
        end
    end

    @testset "reload!" begin
        withserver(TLSConfig(cert("rsa"), key("rsa"); sni = [("a.test", cert("a"), key("a"))])) do p, s
            @test get1(p)["org"] == "-"
            @test reload!(s; cert = cert("renewed"), key = key("renewed")) === s
            r = get1(p)
            @test ok(r) && r["org"] == "renewed" && r["cn"] == "localhost"
            @test get1(p; servername = "a.test")["cn"] == "a.test"
            @test_throws TLSError reload!(s, cert("rsa"), key("ec"))
            @test get1(p)["org"] == "renewed"
            reload!(s, read(cert("b"), String), read(key("b"), String); host = "a.test")
            @test get1(p; servername = "a.test")["cn"] == "b.test"
            reload!(s, cert("rsa"), joinpath(CERTS, "rsa_key_enc.pem"); password = "secret")
            @test get1(p)["org"] == "-"
            # a connection opened before a reload keeps working
            task = @async hget(p, [Dict("path" => "/slow/$(1 << 20)", "expect" => 1 << 20) for _ in 1:30]; keepalive = true)
            for _ in 1:5
                sleep(0.05)
                reload!(s, cert("renewed"), key("renewed"))
                reload!(s, cert("rsa"), key("rsa"))
            end
            rs = fetch(task)
            @test all(r -> ok(r) && r["intact"] == "true" && r["socket"] == "0", rs)
        end
        plain = serve!(app, free_port())
        try
            @test_throws ArgumentError reload!(plain, cert("rsa"), key("rsa"))
        finally
            close(plain)
            wait(plain)
        end
        p = free_port()
        s = serve!(app, p; tls = TLSConfig(cert("rsa"), key("rsa")))
        close(s)
        wait(s)
        @test_throws ArgumentError reload!(s, cert("rsa"), key("rsa"))
    end

    @testset "close with handshakes pending" begin
        p = free_port()
        s = serve!(app, p; tls = TLSConfig(cert("rsa"), key("rsa")))
        spec = Dict{String,Any}("port" => p, "late" => 3000)
        outs = [IOBuffer() for _ in 1:4]
        procs = [run(pipeline(`$NODE $CLIENT $(json(spec))`; stdout = o); wait = false) for o in outs]
        sleep(0.5)
        close(s)
        wait(s)
        foreach(wait, procs)
        @test all(o -> !occursin("reply=HTTP/1.1_200", String(take!(o))), outs)
        withserver(TLSConfig(cert("rsa"), key("rsa"))) do q, s2
            @test ok(get1(q))
        end
    end

    @testset "HTTP and HTTPS servers in one process" begin
        withserver(TLSConfig(cert("ec"), key("ec"))) do p, s
            q = free_port()
            plain = serve!(app, q)
            try
                @test read(`curl -s --max-time 10 http://127.0.0.1:$q/hello`, String) == "hello"
                @test ok(get1(p))
                # plain HTTP on the HTTPS port gets no reply in clear text
                @test read(ignorestatus(`curl -s --max-time 5 http://127.0.0.1:$p/hello`), String) != "hello"
                @test ok(get1(p))
                # an in-process HTTPS client (libcurl) alongside the server's OpenSSL
                io = IOBuffer()
                d = Downloads.Downloader()
                C = Downloads.Curl
                d.easy_hook = (easy, _) -> (C.setopt(easy, C.CURLOPT_SSL_VERIFYPEER, 0); C.setopt(easy, C.CURLOPT_SSL_VERIFYHOST, 0))
                r = Downloads.request("https://127.0.0.1:$p/bytes/300000"; output = io, downloader = d)
                @test r.status == 200 && take!(io) == cached_pattern(300_000)
            finally
                close(plain)
                wait(plain)
            end
        end
    end

    @testset "task handlers and concurrent large bodies" begin
        withserver(TLSConfig(cert("rsa"), key("rsa")); inline = false) do p, s
            sizes = repeat([100_000, 1 << 20, 4 << 20, 1024], 8)
            rs = hget(p, [Dict("path" => "/slow/$n", "expect" => n) for n in sizes]; parallel = true, keepalive = true)
            @test length(rs) == length(sizes)
            @test all(r -> ok(r) && r["intact"] == "true", rs)
            rs = hget(p, [Dict("method" => "POST", "path" => "/echo", "size" => n) for n in sizes]; parallel = true)
            @test all(r -> ok(r) && r["intact"] == "true", rs)
            GC.gc(); GC.gc()
            sleep(0.5)
            @test F.pinned_bodies() == 0
        end
    end

    @testset "writes from tasks reach TLS through the reactor" begin
        @test unsafe_load(cglobal((:fio_flush_elsewhere, F.LIBFJL), Ptr{Cvoid})) != C_NULL
        withserver(TLSConfig(cert("ec"), key("ec")); inline = false) do p, s
            sizes = repeat([1000, 300_000, 3 << 20], 6)
            rs = hget(p, [Dict("path" => "/stream/$n", "expect" => n) for n in sizes]; parallel = true, keepalive = true)
            @test all(r -> ok(r) && r["intact"] == "true", rs)
            for (count, size) in ((200, 100), (50, 70_000), (8, 1 << 20))
                r = wsecho(p; count, size)
                @test !haskey(r, "error") && r["ws_ok"] == string(count) && r["ws_bad"] == "0"
            end
        end
    end
end

end

TLSTests.main()
