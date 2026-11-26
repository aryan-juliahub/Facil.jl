r = http(ex, "POST", "/users/7?page=2&q=a%20b"; headers = ["User-Agent" => "check", "Accept" => "text/html", "ACCEPT" => "application/json"], body = "hello")
@test r.status == 200
lines = split(strip(r.body), "\n")
@test lines[1] == "method: POST"
@test lines[2] == "path: /users/7"
@test lines[3] == "query: page=2&q=a%20b"
@test lines[4] == "version: HTTP/1.1"
@test lines[5] == "host: 127.0.0.1"
@test lines[6] == "user-agent: check"
@test lines[7] == "accept (all): text/html | application/json"
@test lines[8] == "headers: 6"
@test lines[9] == "body bytes: 5"
r = http(ex, "GET", "/")
@test occursin("query: (none)", r.body)
@test occursin("user-agent: (none)", r.body)
# The path is not percent-decoded.
@test occursin("path: /caf%C3%A9", http(ex, "GET", "/caf%C3%A9").body)
# An absolute-form target loses its scheme and host.
@test occursin("path: /abs\nquery: x=1", raw_request(ex, "GET http://example.com/abs?x=1 HTTP/1.1\r\nHost: example.com\r\n\r\n"))
# No Host header: 400, the handler is not called.
@test startswith(raw_request(ex, "GET / HTTP/1.1\r\n\r\n"), "HTTP/1.1 400")
# HTTP/1.0 is answered and the connection closed.
out = raw_request(ex, "GET / HTTP/1.0\r\nHost: x\r\n\r\n")
@test occursin("version: HTTP/1.0", out) && occursin("connection:close", out)
# HEAD: the handler runs, the body is dropped, content-length stays.
h = http(ex, "HEAD", "/")
@test h.status == 200 && h.body == "" && parse(Int, h.headers["content-length"]) > 0
# Expect: 100-continue is answered before the body is read.
out = raw_request(ex, "POST / HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 3\r\n\r\n"; wait = 0.3)
@test startswith(out, "HTTP/1.1 100 Continue")
# The transcript in the guide.
out = curl("-X", "POST", base_url(ex) * "/users/7?page=2&q=a%20b", "-A", "demo", "-H", "Accept: text/html", "-H", "ACCEPT: application/json", "-d", "hello")
@test out == """
    method: POST
    path: /users/7
    query: page=2&q=a%20b
    version: HTTP/1.1
    host: 127.0.0.1:$(ex.port)
    user-agent: demo
    accept (all): text/html | application/json
    headers: 6
    body bytes: 5
    """
# A bare `?` gives no query; an extension method reaches the handler.
@test occursin("query: (none)", http(ex, "GET", "/a?").body)
@test occursin("method: PURGE", http(ex, "PURGE", "/cache").body)
