# mode: process
@test http(ex, "GET", "/users/1").body == "ada\n"
r = http(ex, "GET", "/users/2")
@test r.status == 404
@test r.body == "no such user\n"
r = http(ex, "GET", "/bug")
@test r.status == 500
@test r.body == "internal error, request id 1\n"
@test http(ex, "GET", "/bug").body == "internal error, request id 2\n"
@test wait_until(() -> occursin("GET /bug 500", parentmodule(typeof(ex)).output(ex)))
out = parentmodule(typeof(ex)).output(ex)
@test occursin(r"GET /users/1 200 \d+\.\d ms", out)
@test occursin(r"GET /users/2 404 \d+\.\d ms", out)
@test occursin("request 1 failed", out)
@test occursin("request 2 failed", out)
@test occursin("ArgumentError: invalid base 10 digit", out)
# Facil's own handler-error log never fires: the wrapper caught everything.
@test !occursin("Facil: uncaught error", out)
