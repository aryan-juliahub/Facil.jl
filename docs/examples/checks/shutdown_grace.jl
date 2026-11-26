# mode: process
@test http(ex, "GET", "/").body == "ok"
slow = @async http(ex, "GET", "/report")
Base.sleep(0.3)
t = time()
r = http(ex, "POST", "/shutdown")
@test r.status == 202
@test r.headers["connection"] == "close"
# The request in progress still gets its answer.
@test fetch(slow).body == "report done"
# The process ends once the server has closed, well inside the 5 s grace.
@test wait_until(() -> process_exited(ex.proc); timeout = 10)
@test time() - t < 4
@test ex.proc.exitcode == 0
@test occursin("server closed; cleaning up", parentmodule(typeof(ex)).output(ex))
@test_throws Base.IOError connect("127.0.0.1", ex.port)
