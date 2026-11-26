# needs: JSON
r = http(ex, "GET", "/users")
@test r.status == 200
@test r.headers["content-type"] == "application/json"
@test r.body == """[{"name":"ada","id":1},{"name":"grace","id":2}]""" || r.body == """[{"id":1,"name":"ada"},{"id":2,"name":"grace"}]"""
r = http(ex, "GET", "/users/2")
@test occursin("\"name\":\"grace\"", r.body)
@test http(ex, "GET", "/users/9").status == 404
@test http(ex, "GET", "/users/x").status == 404
r = http(ex, "POST", "/users"; headers = ["Content-Type" => "application/json"], body = """{"name":"linus"}""")
@test r.status == 201
@test occursin("\"id\":3", r.body)
@test occursin("\"name\":\"linus\"", http(ex, "GET", "/users/3").body)
@test http(ex, "POST", "/users"; body = "{oops").status == 400
@test http(ex, "POST", "/users"; body = "{}").status == 400
@test http(ex, "DELETE", "/users/1").status == 404
@test http(ex, "GET", "/").body == """{"error":"not found"}"""
