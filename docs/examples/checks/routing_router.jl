@test http(ex, "GET", "/").body == "home\n"
@test Set(split(http(ex, "GET", "/users").body)) == Set(["ada", "grace"])
@test http(ex, "GET", "/users/").body == http(ex, "GET", "/users").body
@test http(ex, "GET", "/users/1").body == "ada\n"
@test http(ex, "GET", "/users/1?verbose=1").body == "ada\n"
@test http(ex, "GET", "/users/9").status == 404
@test http(ex, "GET", "/users/x").status == 404
@test http(ex, "DELETE", "/users/2").status == 204
@test http(ex, "GET", "/users/2/posts/5").body == "post 5 of user 2\n"
r = http(ex, "PUT", "/users/2"; body = "x")
@test r.status == 405 && r.headers["allow"] == "GET, DELETE"
@test http(ex, "GET", "/nope").status == 404
# The transcript in the guide.
out = curl("-i", "-X", "PUT", base_url(ex) * "/users/2")
@test startswith(out, "HTTP/1.1 405 Method Not Allowed\r\n") && occursin("allow:GET, DELETE\r\n", out)
