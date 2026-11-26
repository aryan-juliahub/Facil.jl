@test http(ex, "GET", "/").status == 404
# A plain GET to the WebSocket path is not a valid upgrade.
@test http(ex, "GET", "/ws").status == 400
a = ws_connect(ex, "/ws")
b = ws_connect(ex, "/ws")
@test startswith(ws_recv(a), "hello guest")
@test startswith(ws_recv(b), "hello guest")
ws_send(a, "/name ada")
@test ws_recv(a) == "you are now ada"
ws_send(a, "hi")
@test ws_recv(a) == "ada #2: hi"
ws_send(b, "hi")
@test ws_recv(b) == "guest #1: hi"
ws_send(b, UInt8[0x01])
@test ws_recv(b) == (:close, 1003)
ws_send(a, "/quit")
@test ws_recv(a) == (:close, 1000)
ws_close(a); ws_close(b)
# A message over max_message_size closes the connection with 1009.
c = ws_connect(ex, "/ws")
ws_recv(c)
ws_send(c, repeat("x", 70_000))
@test ws_recv(c) == (:close, 1009)
ws_close(c)
