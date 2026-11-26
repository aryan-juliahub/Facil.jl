# mode: process
@test wait_until(() -> http(ex, "GET", "/").body == "flaky: 3 runs, open=false; steady open=true")
Base.sleep(0.2)
@test http(ex, "GET", "/").body == "flaky: 3 runs, open=false; steady open=true"
out = parentmodule(typeof(ex)).output(ex)
@test occursin("Facil: uncaught error in a timer callback: tick 3 failed", out)
