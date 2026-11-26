# mode: process
for _ in 1:3
    r = http(ex, "GET", "/throw")
    @test r.status == 500
    @test r.body == "Internal Server Error"
    @test r.headers["content-type"] == "text/plain; charset=utf-8"
end
@test http(ex, "GET", "/number").status == 500
# The server keeps serving.
@test http(ex, "GET", "/").body == "ok"
out = parentmodule(typeof(ex)).output(ex)
# Three errors of one type within 10 s are logged once.
@test length(collect(eachmatch(r"Facil: uncaught error in a request handler: database unavailable", out))) == 1
@test occursin("Facil: uncaught error in a request handler's result: the handler returned a Int64; it must return a Response or a String", out)
