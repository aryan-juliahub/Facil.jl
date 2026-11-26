json = ["Content-Type" => "application/json"]
@test http(ex, "POST", "/api"; headers = json, body = "{}").body == "got 2 bytes of JSON\n"
@test http(ex, "POST", "/api"; body = "x=1").status == 415
@test http(ex, "POST", "/api"; headers = json, body = repeat("x", 70_000)).status == 413
@test http(ex, "POST", "/upload"; body = repeat("x", 200_000)).body == "stored 200000 bytes\n"
# Declared lengths over the caps are refused before the body is sent.
r = raw_request(ex, "POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 9000000\r\n\r\n")
@test startswith(r, "HTTP/1.1 413")
r = raw_request(ex, "POST /api HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: 20000000\r\n\r\n")
@test startswith(r, "HTTP/1.1 413")
r = raw_request(ex, "POST /upload HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n")
@test startswith(r, "HTTP/1.1 411")
# A request head over max_header_size.
@test http(ex, "GET", "/"; headers = ["X-Big-$i" => repeat("a", 1000) for i in 1:9]).status == 431
# A client that trickles its request head (slowloris) gets a 408 once header_timeout has passed.
s = connect("127.0.0.1", ex.port)
write(s, "GET / HTTP/1.1\r\nHost: x\r\n")
reply = @async String(read(s))
t = time()
while !istaskdone(reply) && time() - t < 12
    try
        write(s, "X-Slow: 1\r\n")
    catch
        break
    end
    Base.sleep(0.5)
end
@test startswith(fetch(reply), "HTTP/1.1 408")
@test 4 <= time() - t <= 8
close(s)
