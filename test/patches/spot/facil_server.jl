# Usage: julia facil_server.jl <a|b|c> <port>
include(joinpath(@__DIR__, "FacilServer.jl"))
FacilServer.serve(ARGS[1], ARGS[2])
