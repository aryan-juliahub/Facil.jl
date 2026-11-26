c = ws_connect(ex, "/")
ws_send(c, "a")
@test ws_recv(c) == "echo: a"
ws_send(c, "/count")
@test ws_recv(c) == "1 messages so far"
ws_close(c)
@test http(ex, "GET", "/").status == 400
