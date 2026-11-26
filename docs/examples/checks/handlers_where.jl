# A waiting request does not hold up a quick one.
slow = Threads.@spawn http(ex, "GET", "/wait")
sleep(0.05)
quick = http(ex, "GET", "/quick")
@test quick.status == 200
@test !istaskdone(slow)
@test occursin("/wait ran on thread", fetch(slow).body)
@test occursin("/compute ran on thread", http(ex, "GET", "/compute").body)
@test wait_until(() -> Facil.paused_requests() == 0)
