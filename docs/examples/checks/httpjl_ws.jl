c = ws_connect(ex, "/")
ws_send(c, "ping")
@test ws_recv(c) == "ping"
ws_close(c)
