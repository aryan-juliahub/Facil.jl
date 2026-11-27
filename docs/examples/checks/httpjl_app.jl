@test http(ex, "GET", "/hello").body == "hello world"
r = http(ex, "GET", "/hello?name=Ada%20L")
@test r.body == "hello Ada L"
@test http(ex, "GET", "/hello?name=caf%C3%A9+au+lait").body == "hello café au lait"
@test r.headers["content-type"] == "text/plain"
r = http(ex, "POST", "/echo"; headers = ["Content-Type" => "application/json"], body = "{}")
@test r.body == "{}"
@test r.headers["content-type"] == "application/json"
@test http(ex, "POST", "/echo"; body = "raw").headers["content-type"] == "application/octet-stream"
r = http(ex, "GET", "/nope")
@test r.status == 404
@test r.body == "not found"
