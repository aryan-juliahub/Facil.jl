@test http(ex, "POST", "/notes"; body = "abc").body == "buffered 3 bytes\n"
@test http(ex, "POST", "/upload"; body = repeat("x", 3_000_000)).body == "streamed 3000000 bytes\n"
@test http(ex, "POST", "/import"; body = repeat("line\n", 1000)).body == "spooled 1000 lines\n"
r = http(ex, "POST", "/notes"; body = repeat("x", 100_001))
@test r.status == 413 && r.headers["connection"] == "close"
r = http(ex, "PUT", "/notes"; body = "abc")
@test r.status == 405
# A chunked upload has no declared length.
out = raw_request(ex, "POST /upload HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n")
@test occursin("streamed 5 bytes", out)
# before_body is not called for a request without a body.
@test http(ex, "PUT", "/notes").body == "buffered 0 bytes\n"
