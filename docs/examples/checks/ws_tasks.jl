c = ws_connect(ex, "/"; headers = ["Sec-WebSocket-Protocol" => "resize.v1"])
@test occursin("resize.v1", lowercase(c.head))
ws_send(c, UInt8[1, 2, 3])
ws_send(c, "text")
# One at a time and in order per connection, although the first takes 0.2 s.
@test ws_recv(c) == UInt8[3, 2, 1]
@test ws_recv(c) == "send a binary message"
# Other connections are served while this one waits.
d = ws_connect(ex, "/")
ws_send(c, UInt8[9, 8])
t = time()
ws_send(d, "quick")
@test ws_recv(d) == "send a binary message"
@test time() - t < 0.15
@test ws_recv(c) == UInt8[8, 9]
ws_close(c); ws_close(d)
