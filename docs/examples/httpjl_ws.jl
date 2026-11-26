using Facil

serve("127.0.0.1", 8080) do req
    websocket(req; on_message = (ws, msg) -> send(ws, msg))
end
