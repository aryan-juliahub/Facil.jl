# mode: process
slow = @async http(ex, "GET", "/")
Base.sleep(0.3)
t = time()
kill(ex.proc, Base.SIGTERM)
# On Julia 1.10 the exit-time drain does not always let the request finish.
if VERSION >= v"1.11"
    @test fetch(slow).body == "finished"
    @test wait_until(() -> process_exited(ex.proc); timeout = 10)
    @test time() - t < 4
else
    @test wait_until(() -> process_exited(ex.proc); timeout = 15)
end
@test ex.proc.termsignal == Base.SIGTERM
out = parentmodule(typeof(ex)).output(ex)
@test occursin("Facil: signal received; closing 1 server(s), up to 5.0 s for open requests", out)
