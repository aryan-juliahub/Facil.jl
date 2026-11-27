# mode: process
# env: SITE_ROOT=@repo/docs/examples/site
r = http(ex, "GET", "/")
@test r.status == 200 && r.headers["content-type"] == "text/html; charset=utf-8" && occursin("<h1>Facil</h1>", r.body)
@test http(ex, "GET", "/index.html").body == r.body
@test haskey(r.headers, "etag") && r.headers["accept-ranges"] == "bytes" && r.headers["cache-control"] == "max-age=3600"
css = http(ex, "GET", "/app.css")
@test css.headers["content-type"] == "text/css; charset=utf-8"
# The .gz sibling is sent to clients that accept gzip.
gz = http(ex, "GET", "/app.css"; headers = ["Accept-Encoding" => "gzip"])
@test gz.headers["content-encoding"] == "gzip" && String(Facil.gunzip(Vector{UInt8}(codeunits(gz.body)))) == css.body
@test http(ex, "GET", "/map.geojson").headers["content-type"] == "application/geo+json"
# Conditional and range requests.
@test http(ex, "GET", "/"; headers = ["If-None-Match" => r.headers["etag"]]).status == 304
part = http(ex, "GET", "/index.html"; headers = ["Range" => "bytes=0-14"])
@test part.status == 206 && part.body == "<!doctype html>" && startswith(part.headers["content-range"], "bytes 0-14/")
@test http(ex, "GET", "/index.html"; headers = ["Range" => "bytes=99999-"]).status == 416
h = http(ex, "HEAD", "/index.html")
@test h.status == 200 && h.body == "" && h.headers["content-length"] == string(sizeof(r.body))
# Folders: /docs/ serves docs/index.html, /docs is redirected there.
@test http(ex, "GET", "/docs/").body == "docs index\n"
d = http(ex, "GET", "/docs?x=1")
@test d.status == 301 && d.headers["location"] == "/docs/?x=1"
# Percent-encoded names are decoded; paths with .. are not served.
@test http(ex, "GET", "/release%20notes.txt").body == "notes\n"
@test http(ex, "GET", "/../reports/q3.csv").status == 404
@test http(ex, "GET", "/%2e%2e/reports/q3.csv").status == 404
# Other methods and missing files reach the handler.
@test http(ex, "POST", "/index.html"; body = "x").status == 404
@test http(ex, "GET", "/missing.html").body == "no such page\n"
# sendfile from the handler.
rep = http(ex, "GET", "/reports/q3.csv")
@test rep.status == 200 && rep.body == "quarter,revenue\nq3,100\n"
@test rep.headers["content-type"] == "text/csv; charset=utf-8" && rep.headers["content-disposition"] == "attachment"
@test http(ex, "GET", "/reports/missing.csv").status == 404
@test http(ex, "GET", "/reports/..%2Fpublic%2Findex.html").status == 400
r405 = http(ex, "POST", "/reports/q3.csv"; body = "x")
@test r405.status == 405 && r405.headers["allow"] == "GET, HEAD, OPTIONS"
# If-Range: a matching ETag gives the range, a stale one the whole file.
ir = http(ex, "GET", "/index.html"; headers = ["Range" => "bytes=0-14", "If-Range" => r.headers["etag"]])
@test ir.status == 206 && ir.body == "<!doctype html>"
ir = http(ex, "GET", "/index.html"; headers = ["Range" => "bytes=0-14", "If-Range" => "\"stale\""])
@test ir.status == 200 && ir.body == r.body
# If-Modified-Since gives a 304 for an unchanged file; several ranges give the whole file.
@test http(ex, "GET", "/index.html"; headers = ["If-Modified-Since" => r.headers["last-modified"]]).status == 304
@test http(ex, "GET", "/index.html"; headers = ["Range" => "bytes=0-0,2-2"]).status == 200
@test http(ex, "OPTIONS", "/reports/q3.csv").headers["allow"] == "GET, HEAD"
