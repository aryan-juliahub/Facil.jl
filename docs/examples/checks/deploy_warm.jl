# The script starts a server, requests every route and closes it again.
@test length(ex.servers) == 1
@test !isopen(ex.server)
@test isdefined(example, :app)
