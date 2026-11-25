# Pub/sub

`publish(channel, msg)` sends a message to every subscriber of `channel` in this
process. There are two kinds of subscriber:

- `subscribe(ws, channel)` forwards every message on `channel` straight to a
  WebSocket client. No Julia code runs per message: the frame is built once and
  shared by every subscriber.
- `subscribe(f, channel)` calls `f(msg::String)` for every message, on the reactor
  thread, in publishing order. `spawn = true` runs each call on its own task
  (order is then not kept). It returns a `Subscription`; end it with
  `unsubscribe(sub)`.

A chat room, with a POST endpoint that announces to everyone:

```julia
using Facil

subscribe(msg -> @info("chat", msg), "chat")

serve("127.0.0.1", 8080) do req
    p = path(uri(req))
    if p == "/chat" && Facil.is_upgrade(req)
        websocket(req;
                  on_open = ws -> subscribe(ws, "chat"),
                  on_message = (ws, msg) -> publish("chat", msg))
    elseif p == "/announce" && method(req) == Methods.POST
        publish("chat", body(req))
        Response(StatusCodes.NO_CONTENT)
    else
        Response(StatusCodes.NOT_FOUND, "")
    end
end
```

`publish` works from any thread; delivery happens on the reactor. Pub/sub is
process-local: there is no cluster or Redis engine.

`Facil.slow_subscribers!(; limit, policy)` decides what happens to a WebSocket
subscriber with more than `limit` unsent bytes: `:close` it, `:drop_newest`,
`:drop_oldest` or `:ignore`.

!!! warning
    A process that exits while a `subscribe(f, channel)` subscription is still
    open hangs at exit. Call `unsubscribe(sub)` (or `close(sub)`) before the
    program ends.
