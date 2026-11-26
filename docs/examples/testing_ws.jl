using Facil, Test

#= snippet: logic =#
# Keep what a message does in a function of plain values...
function reply(history::Vector{String}, msg::String)
    msg == "/count" && return "$(length(history)) messages so far"
    push!(history, msg)
    "echo: $msg"
end

# ...so the callbacks only connect it to the socket.
function app(req)
    websocket(req;
              on_open = ws -> (ws.data = String[]),
              on_message = (ws, msg) -> send(ws, reply(ws.data, msg)))
end
#= end =#

#= snippet: tests =#
@testset "reply" begin
    history = String[]
    @test reply(history, "a") == "echo: a"
    @test reply(history, "b") == "echo: b"
    @test reply(history, "/count") == "2 messages so far"
    @test history == ["a", "b"]
end

@testset "upgrade" begin
    # A request that is not a WebSocket upgrade is answered 400 by the server;
    # the handler's own routing can be tested with Facil.is_upgrade.
    plain = Request(Methods.GET, "/", "")
    upgrade = Request(Methods.GET, "/", ""; headers = ["upgrade" => "websocket", "connection" => "Upgrade"])
    @test !Facil.is_upgrade(plain)
    @test Facil.is_upgrade(upgrade)
end
#= end =#

serve(app, "127.0.0.1", 8080)
