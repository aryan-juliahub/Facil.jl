r = http(ex, "GET", "/")
@test r.status == 200
@test r.body == "hello"
@test r.headers["content-type"] == "text/plain; charset=utf-8"
