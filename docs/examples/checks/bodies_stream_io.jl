@test http(ex, "POST", "/"; body = repeat("a line of text\n", 200_000)).body == "200000 lines\n"
@test http(ex, "POST", "/"; body = "no newline").body == "1 lines\n"
@test http(ex, "GET", "/").body == "0 lines\n"
# A client that disconnects half-way: the handler sees BodyAborted and nothing is left behind.
s = connect("127.0.0.1", ex.port)
write(s, "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 1000000\r\n\r\n" * repeat("partial\n", 10))
sleep(0.3)
close(s)
@test wait_until(() -> Facil.pending_bodies() == 0)
@test http(ex, "POST", "/"; body = "a\nb\n").body == "2 lines\n"
