r = http(ex, "GET", "/")
@test r.status == 200 && r.body == join(["line $i\n" for i in 1:5])
@test r.headers["transfer-encoding"] == "chunked" && r.headers["content-type"] == "text/plain; charset=utf-8"
@test !haskey(r.headers, "content-length")
# Each flushed line is its own chunk, and the first arrives before the last is written.
s = connect("127.0.0.1", ex.port)
write(s, "GET / HTTP/1.1\r\nHost: x\r\n\r\n")
t0 = time()
readuntil(s, "line 1\n")
@test time() - t0 < 0.35
# The connection is reusable after the stream ends.
readuntil(s, "0\r\n\r\n")
write(s, "GET / HTTP/1.1\r\nHost: x\r\n\r\n")
@test occursin("200 OK", readuntil(s, "line 1\n"))
close(s)
# HTTP/1.0: no chunking, the body ends when the connection closes.
out = raw_request(ex, "GET / HTTP/1.0\r\nHost: x\r\n\r\n"; wait = 2)
@test occursin("connection:close", out) && !occursin("chunked", out) && endswith(out, "line 5\n")
# HEAD: the head only.
h = http(ex, "HEAD", "/")
@test h.status == 200 && h.body == ""
