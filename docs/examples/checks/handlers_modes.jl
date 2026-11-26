@test length(ex.ports) == 2
@test http(ex.ports[1], "GET", "/").body == "pong"
t = @elapsed r = http(ex.ports[2], "GET", "/")
@test startswith(r.body, "done on thread ")
@test t >= 0.05
@test ex.servers[1].options.inline
@test !ex.servers[2].options.inline
# Twenty slow requests at once finish in about one sleep, not twenty.
t = @elapsed begin
    tasks = [Threads.@spawn http(ex.ports[2], "GET", "/") for _ in 1:20]
    @test all(x -> fetch(x).status == 200, tasks)
end
@test t < 0.9
