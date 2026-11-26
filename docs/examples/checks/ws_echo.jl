r = http(ex, "GET", "/")
@test r.status == 426
@test r.body == "WebSocket only"
c = ws_connect(ex, "/")
@test ws_recv(c) == "welcome"
ws_send(c, "hello")
@test ws_recv(c) == "hello"
ws_send(c, UInt8[1, 2, 3])
@test ws_recv(c) == UInt8[1, 2, 3]
n = Facil.open_websockets()
@test n >= 1
ws_close(c)
@test wait_until(() -> Facil.open_websockets() == n - 1)
