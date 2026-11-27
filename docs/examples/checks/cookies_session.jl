r = http(ex, "GET", "/login")
@test r.status == 200
out = raw_request(ex, "GET /login HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
@test occursin("set-cookie:sid=abc123; Path=/; Max-Age=3600; HttpOnly; SameSite=Lax\r\n", out)
@test occursin("set-cookie:theme=dark%20mode; Path=/\r\n", out)
@test http(ex, "GET", "/me").status == 401
@test http(ex, "GET", "/me"; headers = ["Cookie" => "sid=xyz"]).body == "session xyz, theme light\n"
jar = tempname()
try
    base = base_url(ex)
    @test curl("-c", jar, "$base/login") == "logged in\n"
    @test curl("-b", jar, "$base/me") == "session abc123, theme dark mode\n"
    @test curl("-b", jar, "-c", jar, "$base/logout") == "logged out\n"
    @test curl("-b", jar, "$base/me") == "no session\n"
finally
    rm(jar; force = true)
end
