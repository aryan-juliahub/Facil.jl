r = http(ex, "GET", "/text")
@test r.status == 200 && r.headers["content-type"] == "text/plain; charset=utf-8"
@test r.headers["content-length"] == string(sizeof(r.body))
@test haskey(r.headers, "date") && haskey(r.headers, "last-modified") && r.headers["connection"] == "close"
r = http(ex, "GET", "/html")
@test r.headers["content-type"] == "text/html; charset=utf-8" && r.body == "<h1>hello</h1>\n"
r = http(ex, "GET", "/bytes")
@test r.headers["content-type"] == "image/png" && codeunits(r.body) == example.PNG_PIXEL
r = http(ex, "GET", "/created")
@test r.status == 201 && r.headers["location"] == "/things/1" && r.headers["x-request-id"] == "42"
r = http(ex, "GET", "/empty")
@test r.status == 204 && r.body == "" && !haskey(r.headers, "content-type") && !haskey(r.headers, "content-length")
r = http(ex, "GET", "/old")
@test r.status == 301 && r.headers["location"] == "/text" && r.body == ""
out = raw_request(ex, "GET /cookies HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
@test occursin("set-cookie:a=1; Path=/\r\n", out) && occursin("set-cookie:b=2; Path=/\r\n", out)
r = http(ex, "GET", "/busy")
@test r.status == 503 && r.headers["retry-after"] == "30"
r = redirect_stderr(devnull) do
    http(ex, "GET", "/boom")
end
@test r.status == 500 && r.body == "Internal Server Error" && r.headers["content-type"] == "text/plain; charset=utf-8"
@test http(ex, "GET", "/nope").status == 404
h = http(ex, "HEAD", "/html")
@test h.status == 200 && h.body == "" && h.headers["content-length"] == "15"
# The connection stays open after a response, 500s included.
out = redirect_stderr(devnull) do
    raw_request(ex, "GET /boom HTTP/1.1\r\nHost: x\r\n\r\nGET /text HTTP/1.1\r\nHost: x\r\n\r\n")
end
@test occursin("500 Internal Server Error", out) && occursin("a plain String", out)
