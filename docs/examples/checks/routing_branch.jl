@test http(ex, "GET", "/").body == "home\n"
@test http(ex, "GET", "/?x=1").body == "home\n"
@test http(ex, "GET", "/users/7").body == "user 7\n"
@test http(ex, "GET", "/users/abc").status == 400
r = http(ex, "DELETE", "/users/7")
@test r.status == 405 && r.headers["allow"] == "GET"
@test http(ex, "POST", "/"; body = "x").status == 405
@test http(ex, "GET", "/nope").status == 404
# HEAD is its own method: this app answers it 405.
@test http(ex, "HEAD", "/").status == 405
@test startswith(curl("-i", "-X", "DELETE", base_url(ex) * "/users/7"), "HTTP/1.1 405 Method Not Allowed\r\n")
@test http(ex, "GET", "/users/7/").status == 400
@test http(ex, "GET", "//users/7").status == 404
