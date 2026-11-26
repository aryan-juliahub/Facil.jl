r = http(ex, "GET", "/")
@test r.status == 200
@test r.headers["transfer-encoding"] == "chunked"
@test r.headers["content-type"] == "text/plain"
@test r.body == "line 1\nline 2\nline 3\n"
