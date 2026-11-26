# mode: process
# env: HOST=127.0.0.1 PORT=8080
@test http(ex, "GET", "/health").body == "ok"
@test startswith(http(ex, "GET", "/").body, "up for ")
@test http(ex, "GET", "/nope").status == 404
@test http(ex, "POST", "/"; body = "x"^(2 << 20)).status == 413
@test wait_until(() -> occursin("listening on http://127.0.0.1:", DocExamples.output(ex)))
@test occursin("handlers on tasks", DocExamples.output(ex))
# SIGTERM drains and ends the process with status 143.
kill(ex.proc, Base.SIGTERM)
@test wait_until(() -> process_exited(ex.proc); timeout = 30)
@test ex.proc.termsignal == Base.SIGTERM || ex.proc.exitcode == 143
@test occursin("signal received; closing 1 server(s)", DocExamples.output(ex))
