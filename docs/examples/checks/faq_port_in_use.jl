# servers: 2
@test example.second isa SystemError
@test occursin("Address already in use", sprint(showerror, example.second))
@test http(ex.ports[1], "GET", "/").body == "first"
@test http(ex.ports[2], "GET", "/").body == "other"
