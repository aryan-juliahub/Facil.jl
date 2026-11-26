# servers: 1
r = http(ex, "GET", "/metrics")
@test r.status == 200
lines = split(strip(r.body), '\n')
@test length(lines) == 6
@test startswith(lines[1], "facil_connections ")
@test parse(Int, split(lines[1])[2]) >= 1
@test parse(Int, split(lines[2])[2]) == 1
@test all(l -> tryparse(Int, split(l)[2]) !== nothing, lines)
@test http(ex, "GET", "/").body == "hello"
