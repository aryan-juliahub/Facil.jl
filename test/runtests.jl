using Test

@testset "Facil" begin
    include("core.jl")
    include("server.jl")
    include("timers.jl")
    include("async.jl")
    include("body.jl")
    include("robust.jl")
    include("static.jl")
    include("streaming.jl")
    include("sse.jl")
    include("websockets.jl")
    include("pubsub.jl")
    include("compress.jl")
    include("tls.jl")
    include("exit.jl")
    include("conn_scale.jl")
    include("gc.jl")
    include("names.jl")
    include("docs_examples.jl")
end
