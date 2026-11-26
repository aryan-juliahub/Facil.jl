a = ws_connect(ex, "/chat")
b = ws_connect(ex, "/chat")
Base.sleep(0.2)
ws_send(a, "hi from a")
@test ws_recv(a) == "hi from a"
@test ws_recv(b) == "hi from a"
@test http(ex, "POST", "/announce"; body = "lunch").status == 204
@test ws_recv(a) == "announcement: lunch"
@test ws_recv(b) == "announcement: lunch"
@test wait_until(() -> http(ex, "GET", "/history").body == "hi from a\nannouncement: lunch")
@test isopen(example.log_subscription)
ws_close(a); ws_close(b)
@test http(ex, "GET", "/nope").status == 404
