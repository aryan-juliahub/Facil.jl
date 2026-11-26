@test http(ex, "POST", "/"; body = repeat("a", 1000)).body == "1000 bytes\n"
r = http(ex, "GET", "/"; headers = ["X-Big" => repeat("a", 9000)])
@test r.status == 431 && r.body == "Request Header Fields Too Large"
r = http(ex, "POST", "/"; body = repeat("a", 64 * 1024 + 1))
@test r.status == 413 && r.body == "Payload Too Large"
# Over max_body_size: refused from the declared length, before any body is sent.
out = raw_request(ex, "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 2000000\r\n\r\n")
@test startswith(out, "HTTP/1.1 413") && occursin("connection:close", out)
