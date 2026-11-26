# mode: process
# env: DRAIN_TOKEN=s3cret
@test http(ex, "POST", "/admin/drain").status == 403
slow = @async http(ex, "GET", "/")
Base.sleep(0.3)
r = http(ex, "POST", "/admin/drain"; headers = ["X-Drain-Token" => "s3cret"])
@test (r.status, r.body) == (202, "draining\n")
# The request in flight, which waits on Julia's event loop, still gets its answer.
@test fetch(slow).body == "finished\n"
@test wait_until(() -> process_exited(ex.proc); timeout = 20)
ex.proc.exitcode == 0 || println("exit status ", ex.proc.exitcode, "; output:\n", parentmodule(typeof(ex)).output(ex))
@test ex.proc.exitcode == 0
@test occursin("drained; exiting", output(ex))
