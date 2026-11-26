# needs: JSON
using JSON
J = ["Content-Type" => "application/json"]
r = http(ex, "GET", "/status")
@test r.status == 200 && r.headers["content-type"] == "application/json"
@test JSON.parse(r.body)["status"] == "ok"
r = http(ex, "POST", "/greet"; headers = J, body = """{"name":"Ada"}""")
@test r.status == 201 && JSON.parse(r.body) == Dict("greeting" => "hello Ada", "length" => 3)
r = http(ex, "POST", "/greet"; headers = ["Content-Type" => "application/json; charset=utf-8"], body = """{"name":"Zoë"}""")
@test JSON.parse(r.body)["greeting"] == "hello Zoë"
r = http(ex, "POST", "/greet"; headers = J, body = "{not json")
@test r.status == 400 && JSON.parse(r.body)["error"] == "the body must be a JSON object"
@test http(ex, "POST", "/greet"; headers = J, body = "[1,2]").status == 400
@test http(ex, "POST", "/greet"; headers = J).status == 400
@test http(ex, "POST", "/greet"; headers = J, body = """{"name":7}""").status == 422
@test http(ex, "POST", "/greet"; body = """{"name":"Ada"}""").status == 415
r = http(ex, "GET", "/nope")
@test r.status == 404 && r.headers["content-type"] == "application/json"
# Over body_in_memory: Facil answers 413 itself, as plain text.
r = http(ex, "POST", "/greet"; headers = J, body = "\"" * repeat("a", 1024 * 1024) * "\"")
@test r.status == 413 && r.body == "Payload Too Large"
# The transcript in the guide.
@test curl(base_url(ex) * "/greet", "-H", "Content-Type: application/json", "-d", """{"name":"Ada"}""") == """{"greeting":"hello Ada","length":3}"""
@test curl(base_url(ex) * "/greet", "-H", "Content-Type: application/json", "-d", "{not json") == """{"error":"the body must be a JSON object"}"""
