using Facil

serve("127.0.0.1", 8080) do req
    Facil.is_upgrade(req) || return Response(StatusCodes.UPGRADE_REQUIRED, "WebSocket only";
                                             headers = [header.UPGRADE => "websocket"])
    websocket(req;
              on_open = ws -> send(ws, "welcome"),
              on_message = (ws, msg) -> send(ws, msg),
              on_close = ws -> println("client gone"))
end
