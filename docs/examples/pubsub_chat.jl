using Facil

# Runs on the reactor thread for every message, in publishing order.
const HISTORY = String[]
const log_subscription = subscribe("chat") do msg
    push!(HISTORY, msg)
    length(HISTORY) > 100 && popfirst!(HISTORY)
end

serve("127.0.0.1", 8080) do req
    m, p = method(req), path(uri(req))
    if p == "/chat" && Facil.is_upgrade(req)
        websocket(req;
                  on_open = ws -> subscribe(ws, "chat"),
                  on_message = (ws, msg) -> publish("chat", msg))
    elseif p == "/announce" && m == Methods.POST
        publish("chat", "announcement: " * body(req))
        Response(StatusCodes.NO_CONTENT)
    elseif p == "/history" && m == Methods.GET
        Response(StatusCodes.OK, join(HISTORY, "\n"))
    else
        Response(StatusCodes.NOT_FOUND, "not found")
    end
end

unsubscribe(log_subscription)
