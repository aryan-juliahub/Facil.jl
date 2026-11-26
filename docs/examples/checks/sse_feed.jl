a = sse_open(ex, "/feed")
b = sse_open(ex, "/feed")
@test wait_until(() -> length(example.CLIENTS) == 2)
@test http(ex, "POST", "/publish"; body = "first\nsecond line").status == 202
@test sse_next(a) == Dict("event" => "message", "data" => "first\nsecond line")
@test sse_next(b) == Dict("event" => "message", "data" => "first\nsecond line")
close(a.sock)
http(ex, "POST", "/publish"; body = "after a left")
@test sse_next(b)["data"] == "after a left"
close(b.sock)
