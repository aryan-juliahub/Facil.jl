using Facil

first = serve!(req -> "first", "127.0.0.1", 8080)

# A second server on the same address fails with a SystemError.
second = try
    serve!(req -> "second", "127.0.0.1", port(first))
catch err
    err
end

println(second isa SystemError)                 # true
println(sprint(showerror, second))              # ...: Address already in use

# Port 0 asks the system for any free port.
other = serve!(req -> "other", "127.0.0.1", 0)
println(port(other) != port(first))             # true

wait(first)
