# Compression: codecs, Accept-Encoding negotiation, whole-body compression by
# serve!(...; compress), and compressed streams.
module M6CompressTests

using Facil, Test, Sockets
isdefined(Main, :M6Http) || Main.include(joinpath(@__DIR__, "m6_http.jl"))
using Main.M6Http
import Main.M6Http

const COMPRESS_PORTS = 3785:3794

const TEXT_BODY = join(("{\"id\":$i,\"name\":\"user$i\",\"tags\":[\"a\",\"b\"]}" for i in 1:400), ",")

decode(enc, b) = enc == "gzip" ? Facil.gunzip(b) : enc == "br" ? Facil.unbrotli(b) : enc == "zstd" ? Facil.unzstd(b) : b
# Some platforms have no working brotli decoder (see docs/src/reference/platforms.md);
# there the brotli round trips are recorded as broken instead of run.
const UNBROTLI = Facil.brotli_decoder_works()
macro brtest(enc, ex)
    :(($(esc(enc)) in ("br", :br) && !UNBROTLI) ? @test_broken(false) : @test($(esc(ex))))
end

function compress_app(req)
    p = path(uri(req))
    p == "/text" && return Response(StatusCodes.OK, TEXT_BODY; headers = [header.CONTENT_TYPE => "application/json"])
    p == "/string" && return TEXT_BODY
    p == "/small" && return Response(StatusCodes.OK, "tiny"; headers = [header.CONTENT_TYPE => "text/plain"])
    p == "/png" && return Response(StatusCodes.OK, Vector{UInt8}(TEXT_BODY); headers = [header.CONTENT_TYPE => "image/png"])
    p == "/bytes" && return Response(StatusCodes.OK, Vector{UInt8}(TEXT_BODY))
    p == "/encoded" && return Response(StatusCodes.OK, TEXT_BODY; headers = [header.CONTENT_TYPE => "text/plain", header.CONTENT_ENCODING => "identity"])
    p == "/notransform" && return Response(StatusCodes.OK, TEXT_BODY; headers = [header.CONTENT_TYPE => "text/plain", header.CACHE_CONTROL => "no-transform"])
    p == "/vary" && return Response(StatusCodes.OK, TEXT_BODY; headers = [header.CONTENT_TYPE => "text/plain", header.VARY => "origin"])
    p == "/nocontent" && return Response(StatusCodes.NO_CONTENT)
    if p == "/stream"
        return stream(req; headers = [header.CONTENT_TYPE => "text/plain"]) do io
            for i in 1:50
                write(io, TEXT_BODY)
                i % 10 == 0 && flush(io)
            end
        end
    elseif startswith(p, "/forced/")
        alg = Symbol(p[9:end])
        return stream(req; compress = alg, level = 1, headers = [header.CONTENT_TYPE => "application/octet-stream"]) do io
            write(io, TEXT_BODY)
        end
    elseif p == "/stream-none"
        return stream(req; compress = nothing, headers = [header.CONTENT_TYPE => "text/plain"]) do io
            write(io, TEXT_BODY)
        end
    end
    Response(StatusCodes.NOT_FOUND)
end

const AE_ALL = ["Accept-Encoding" => "gzip, deflate, br, zstd"]

@testset "compress" begin
    @testset "codecs" begin
        for data in (UInt8[], Vector{UInt8}("a"), Vector{UInt8}(TEXT_BODY), rand(UInt8, 300_000), repeat(Vector{UInt8}(TEXT_BODY), 50))
            @test Facil.gunzip(Facil.gzip(data)) == data
            @test Facil.gunzip(Facil.gzip(data; level = 1)) == data
            @test Facil.unzstd(Facil.zstd(data)) == data
            @brtest :br Facil.unbrotli(Facil.brotli(data)) == data
            @brtest :br Facil.unbrotli(Facil.brotli(data; level = 5)) == data
            @test !isempty(Facil.brotli(data))
        end
        @test Facil.gunzip(Facil.gzip(TEXT_BODY)) == Vector{UInt8}(TEXT_BODY)
        @test length(Facil.gzip(TEXT_BODY)) < sizeof(TEXT_BODY) ÷ 4
        # the stream encoders, through every flush pattern
        for enc in (:gzip, :br, :zstd), pattern in (:none, :flush, :big)
            e = Facil.stream_encoder(enc, Facil.default_level(enc))
            out = UInt8[]
            sink = z -> append!(out, z)
            src = pattern === :big ? repeat(Vector{UInt8}(TEXT_BODY), 20) : Vector{UInt8}(TEXT_BODY)
            for k in 1:3
                GC.@preserve src Facil.encode!(sink, e, pointer(src), length(src))
                pattern === :flush && Facil.encode_flush!(sink, e)
            end
            Facil.encode_finish!(sink, e)
            Facil.encoder_free!(e)
            @brtest enc decode(string(Facil.ENCODING_NAMES[enc]), out) == repeat(src, 3)
        end
    end

    @testset "negotiation" begin
        pref = [:zstd, :br, :gzip]
        @test Facil.negotiate("gzip, deflate, br, zstd", pref) === :zstd
        @test Facil.negotiate("gzip, deflate, br", pref) === :br
        @test Facil.negotiate("gzip", pref) === :gzip
        @test Facil.negotiate("GZIP", pref) === :gzip
        @test Facil.negotiate("x-gzip", pref) === :gzip
        @test Facil.negotiate("identity", pref) === :none
        @test Facil.negotiate("", pref) === :none
        @test Facil.negotiate("zstd;q=0, br;q=0.5, gzip;q=0.8", pref) === :gzip
        @test Facil.negotiate("zstd;q=0, *", pref) === :br
        @test Facil.negotiate("*;q=0", pref) === :none
        @test Facil.negotiate("gzip;q=1.0, br; q=1", pref) === :br
        @test Facil.negotiate("br, gzip", [:gzip, :br]) === :gzip
        @test Facil.negotiate("gzip;q=abc", pref) === :none
        @test Facil.compressible_type("text/html; charset=utf-8")
        @test Facil.compressible_type("application/json")
        @test Facil.compressible_type("application/vnd.api+json")
        @test Facil.compressible_type("image/svg+xml")
        @test !Facil.compressible_type("image/png")
        @test !Facil.compressible_type("application/octet-stream")
        @test !Facil.compressible_type("application/zip")
        @test_throws ArgumentError CompressOptions(prefer = (:lz4,))
        @test_throws ArgumentError CompressOptions(gzip = 13)
        @test_throws ArgumentError serve!(compress_app, COMPRESS_PORTS[9]; compress = :yes)
    end

    for inline in (true, false)
        @testset "server, inline = $inline" begin
            srv = serve!(compress_app, COMPRESS_PORTS[1 + inline]; inline, compress = true)
            port = Facil.port(srv)
            try
                r = get1(port, "/text"; headers = AE_ALL)
                @test r["content-encoding"] == "zstd"
                @test r["vary"] == "accept-encoding"
                @test r["content-type"] == "application/json"
                @test String(decode("zstd", r.body)) == TEXT_BODY
                @test parse(Int, r["content-length"]) == length(r.body) < sizeof(TEXT_BODY)
                for (ae, enc) in (("gzip", "gzip"), ("br;q=1, gzip;q=0.5", "br"), ("zstd", "zstd"))
                    r = get1(port, "/text"; headers = ["Accept-Encoding" => ae])
                    @test r["content-encoding"] == enc
                    @brtest enc String(decode(enc, r.body)) == TEXT_BODY
                    enc == "br" && @test r.body == Facil.brotli(TEXT_BODY)
                end
                r = get1(port, "/text")
                @test !haskey(r, "content-encoding") && r["vary"] == "accept-encoding"
                @test String(r.body) == TEXT_BODY
                r = get1(port, "/string"; headers = AE_ALL)
                @test r["content-encoding"] == "zstd"
                @test r["content-type"] == "text/plain; charset=utf-8"
                @test String(decode("zstd", r.body)) == TEXT_BODY
                r = get1(port, "/text"; method = "HEAD", headers = ["Accept-Encoding" => "gzip"])
                @test r["content-encoding"] == "gzip" && isempty(r.body)
                for p in ("/small", "/png", "/bytes", "/encoded", "/notransform")
                    r = get1(port, p; headers = AE_ALL)
                    @test get(r.headers, "content-encoding", "identity") == "identity"
                    @test length(r.body) == (p == "/small" ? 4 : sizeof(TEXT_BODY))
                end
                @test get1(port, "/nocontent"; headers = AE_ALL).status == 204
                r = get1(port, "/vary"; headers = ["Accept-Encoding" => "gzip"])
                @test r["vary"] == "origin, accept-encoding"

                # streams follow the server's choice; explicit encodings are honoured
                r = get1(port, "/stream"; headers = ["Accept-Encoding" => "gzip"])
                @test r["content-encoding"] == "gzip" && r["transfer-encoding"] == "chunked"
                @test String(decode("gzip", r.body)) == TEXT_BODY^50
                r = get1(port, "/stream"; headers = AE_ALL)
                @test r["content-encoding"] == "zstd"
                @test String(decode("zstd", r.body)) == TEXT_BODY^50
                r = get1(port, "/stream"; headers = ["Accept-Encoding" => "br"])
                @brtest "br" String(decode("br", r.body)) == TEXT_BODY^50
                r = get1(port, "/stream")
                @test !haskey(r, "content-encoding") && String(r.body) == TEXT_BODY^50
                for alg in ("gzip", "br", "zstd")
                    r = get1(port, "/forced/$alg")
                    @test r["content-encoding"] == alg
                    @brtest alg String(decode(alg, r.body)) == TEXT_BODY
                end
                r = get1(port, "/stream-none"; headers = AE_ALL)
                @test !haskey(r, "content-encoding") && String(r.body) == TEXT_BODY
            finally
                close(srv); wait(srv)
            end
        end
    end

    @testset "options" begin
        o = CompressOptions(prefer = (:gzip,), gzip = 1, min_size = 10, compressible = ct -> true)
        srv = serve!(compress_app, COMPRESS_PORTS[3]; compress = o)
        port = Facil.port(srv)
        try
            r = get1(port, "/png"; headers = AE_ALL)
            @test r["content-encoding"] == "gzip"
            @test String(decode("gzip", r.body)) == TEXT_BODY
            r = get1(port, "/text"; headers = ["Accept-Encoding" => "br, zstd"])
            @test !haskey(r, "content-encoding")
        finally
            close(srv); wait(srv)
        end
        srv = serve!(compress_app, COMPRESS_PORTS[4])
        port = Facil.port(srv)
        try
            r = get1(port, "/text"; headers = AE_ALL)
            @test !haskey(r, "content-encoding") && !haskey(r, "vary")
            r = get1(port, "/forced/gzip")
            @test r["content-encoding"] == "gzip"
        finally
            close(srv); wait(srv)
        end
    end
end

end
