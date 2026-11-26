r = http(ex, "GET", "/")
@test r.status == 401
@test r.headers["www-authenticate"] == "Bearer"
@test r.headers["access-control-allow-origin"] == "https://app.example.com"
@test http(ex, "GET", "/"; headers = ["Authorization" => "Bearer wrong"]).status == 401
@test http(ex, "GET", "/"; headers = ["Authorization" => "Bearer change-me-not"]).status == 401
r = http(ex, "GET", "/"; headers = ["Authorization" => "Bearer change-me"])
@test r.status == 200
@test r.body == "the secret data\n"
@test r.headers["access-control-allow-origin"] == "https://app.example.com"
@test r.headers["vary"] == "origin"
r = http(ex, "OPTIONS", "/"; headers = ["Origin" => "https://app.example.com", "Access-Control-Request-Method" => "POST"])
@test r.status == 204
@test r.headers["access-control-allow-methods"] == "GET, POST, OPTIONS"
@test example.same_secret("abc", "abc")
@test !example.same_secret("abc", "abd")
@test !example.same_secret("abc", "abcd")
