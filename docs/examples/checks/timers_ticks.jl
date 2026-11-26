@test wait_until(() -> occursin("ready=true", http(ex, "GET", "/").body); timeout = 5)
t = time()
@test http(ex, "GET", "/slow").body == "waited 50 ms"
@test time() - t >= 0.05
n1 = example.TICKS[]
Base.sleep(0.55)
n2 = example.TICKS[]
@test 3 <= n2 - n1 <= 7
@test occursin("ticker=running", http(ex, "GET", "/").body)
@test startswith(http(ex, "GET", "/stop").body, "ticker stopped at ")
n3 = example.TICKS[]
Base.sleep(0.3)
@test example.TICKS[] == n3
@test occursin("ticker=stopped", http(ex, "GET", "/").body)
