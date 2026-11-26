bytes(r) = Vector{UInt8}(codeunits(r.body))
plain = http(ex, "GET", "/")
@test plain.body == example.PAGE && !haskey(plain.headers, "content-encoding") && plain.headers["vary"] == "accept-encoding"
gz = http(ex, "GET", "/"; headers = ["Accept-Encoding" => "gzip"])
@test gz.headers["content-encoding"] == "gzip" && gz.headers["vary"] == "accept-encoding"
@test sizeof(gz.body) < 200 && String(Facil.gunzip(bytes(gz))) == example.PAGE
# zstd is preferred when the client accepts several.
z = http(ex, "GET", "/"; headers = ["Accept-Encoding" => "gzip, br, zstd"])
@test z.headers["content-encoding"] == "zstd" && String(Facil.unzstd(bytes(z))) == example.PAGE
br = http(ex, "GET", "/"; headers = ["Accept-Encoding" => "gzip, br"])
@test br.headers["content-encoding"] == "br" && bytes(br) == Facil.brotli(example.PAGE)
# Not every platform has a working brotli decoder (see Platform support).
Facil.brotli_decoder_works() && @test String(Facil.unbrotli(bytes(br))) == example.PAGE
# q-values win over the server's order.
q = http(ex, "GET", "/"; headers = ["Accept-Encoding" => "zstd;q=0.1, gzip;q=0.9"])
@test q.headers["content-encoding"] == "gzip"
@test !haskey(http(ex, "GET", "/"; headers = ["Accept-Encoding" => "zstd;q=0, identity"]).headers, "content-encoding")
# Small bodies and incompressible types are sent as they are.
s = http(ex, "GET", "/small"; headers = ["Accept-Encoding" => "gzip"])
@test s.body == "under 1 KiB, sent as is\n" && !haskey(s.headers, "content-encoding") && !haskey(s.headers, "vary")
p = http(ex, "GET", "/photo"; headers = ["Accept-Encoding" => "gzip"])
@test sizeof(p.body) == 4096 && !haskey(p.headers, "content-encoding")
# Streams are compressed as they are written.
l = http(ex, "GET", "/lines"; headers = ["Accept-Encoding" => "gzip"])
@test l.headers["content-encoding"] == "gzip" && l.headers["transfer-encoding"] == "chunked"
text = String(Facil.gunzip(bytes(l)))
@test count(==('\n'), text) == 2000 && endswith(text, "line 2000 of a compressed stream\n")
@test http(ex, "GET", "/lines").body == text
# curl's own decoder agrees.
@test curl("--compressed", base_url(ex) * "/") == example.PAGE
# The transcript in the guide.
head = curl("-H", "Accept-Encoding: gzip", "-D", "-", "-o", "/dev/null", base_url(ex) * "/")
@test occursin("content-encoding:gzip\r\n", head) && occursin("vary:accept-encoding\r\n", head)
@test startswith(curl("--compressed", base_url(ex) * "/"), "<p>hello</p>\n<p>hello</p>\n")
# `*` stands for encodings not named; a stream is compressed without a size test.
@test http(ex, "GET", "/"; headers = ["Accept-Encoding" => "*"]).headers["content-encoding"] == "zstd"
