# The values written in the example are the defaults in the code.
written = ex.server.options
default = Facil.ServerOptions()
for f in fieldnames(Facil.ServerOptions)
    f === :before_body && continue
    @test getfield(written, f) == getfield(default, f)
end
@test default.before_body(Facil.RequestHead(Methods.POST, Uri("/"), Versions.HTTP_11, HeaderMap{HeaderValue}(), 0)) === Buffer()
@test http(ex, "GET", "/").body == "ok"
@test http(ex, "POST", "/"; body = "abc").body == "ok"
