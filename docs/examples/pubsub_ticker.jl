using Facil

# A client more than 1 MiB behind misses new ticks instead of being disconnected.
Facil.slow_subscribers!(limit = 1024 * 1024, policy = :drop_newest)

const SEQ = Threads.Atomic{Int}(0)

# Publishing works from any thread; this runs on a Julia task every 50 ms.
const ticker = every(50) do
    n = Threads.atomic_add!(SEQ, 1) + 1
    publish("ticks", "tick $n")
    true
end

serve("127.0.0.1", 8080) do req
    p = path(uri(req))
    if p == "/ticks" && Facil.is_upgrade(req)
        websocket(req; on_open = ws -> subscribe(ws, "ticks"),
                  on_message = (ws, msg) -> msg == "stop" && unsubscribe(ws, "ticks"))
    elseif p == "/stats"
        s = Facil.slow_subscriber_stats()
        Response(StatusCodes.OK, "dropped=$(s.dropped) closed=$(s.closed)")
    else
        Response(StatusCodes.NOT_FOUND, "not found")
    end
end
