bytes(r) = Vector{UInt8}(codeunits(r.body))
all3 = ["Accept-Encoding" => "zstd, br, gzip"]
r = http(ex, "GET", "/items"; headers = all3)
@test r.headers["content-encoding"] == "br" && String(Facil.unbrotli(bytes(r))) == example.DATA
r = http(ex, "GET", "/items"; headers = ["Accept-Encoding" => "zstd, gzip"])
@test r.headers["content-encoding"] == "gzip" && String(Facil.gunzip(bytes(r))) == example.DATA
r = http(ex, "GET", "/items"; headers = ["Accept-Encoding" => "zstd"])
@test !haskey(r.headers, "content-encoding") && r.body == example.DATA
@test http(ex, "GET", "/legacy"; headers = all3).body == example.DATA
x = http(ex, "GET", "/exact"; headers = all3)
@test x.body == example.DATA && !haskey(x.headers, "content-encoding")
a = http(ex, "GET", "/archive"; headers = all3)
@test a.headers["content-encoding"] == "zstd" && String(Facil.unzstd(bytes(a))) == example.DATA
# compress = :gzip on a stream does not look at Accept-Encoding.
l = http(ex, "GET", "/live")
@test l.headers["content-encoding"] == "gzip" && String(Facil.gunzip(bytes(l))) == "update 1\nupdate 2\nupdate 3\n"
