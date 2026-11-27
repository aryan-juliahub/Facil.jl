# needs: JSON
# The file serves only when run as a program, so the check starts the app itself.
server = Facil.serve!(example.app, 0; max_body_size = 64 * 1024)
try
    r = http(port(server), "POST", "/notes"; body = """{"title": "Buy milk", "text": "2 litres"}""")
    @test r.status == 201
    @test r.headers["location"] == "/notes/1"
    @test r.headers["content-type"] == "application/json"
    @test r.body == """{"id":1,"title":"Buy milk","text":"2 litres"}"""
    @test http(port(server), "GET", "/notes").body == """[{"id":1,"title":"Buy milk","text":"2 litres"}]"""
    @test http(port(server), "GET", "/notes?q=MILK").body == """[{"id":1,"title":"Buy milk","text":"2 litres"}]"""
    @test http(port(server), "GET", "/notes?q=bread").body == "[]"
    r = http(port(server), "POST", "/notes"; body = "{oops")
    @test (r.status, r.body) == (400, """{"error":"the body is not valid JSON"}""")
    @test http(port(server), "POST", "/notes"; body = "[1]").status == 400
    r = http(port(server), "POST", "/notes"; body = """{"text": "x"}""")
    @test (r.status, r.body) == (422, """{"error":"title is required"}""")
    @test http(port(server), "GET", "/notes/1").status == 200
    r = http(port(server), "GET", "/notes/7")
    @test (r.status, r.body) == (404, """{"error":"no note 7"}""")
    r = http(port(server), "PUT", "/notes/1")
    @test (r.status, r.headers["allow"]) == (405, "GET, DELETE")
    @test http(port(server), "DELETE", "/notes/1").status == 204
    @test http(port(server), "DELETE", "/notes/1").status == 404
    @test http(port(server), "GET", "/health").body == "ok"
    @test http(port(server), "GET", "/nope").status == 404
    r = http(port(server), "POST", "/notes"; body = "x"^70_000)
    @test r.status == 413
finally
    close(server)
end
