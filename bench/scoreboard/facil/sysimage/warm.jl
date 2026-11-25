# Runs the scoreboard server briefly so the sysimage holds what its first requests compile.
empty!(ARGS); push!(ARGS, "3591")
t = @async include(joinpath(@__DIR__, "..", "server.jl"))
for _ in 1:600
    success(`curl -s -o /dev/null http://127.0.0.1:3591/json`) && break
    sleep(0.1)
end
for path in ("/json", "/tiny", "/bytes/100", "/hdr", "/fnv16k")
    run(pipeline(`curl -s http://127.0.0.1:3591$path`, devnull))
end
close(server)
