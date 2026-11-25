# WebSockets

A handler accepts a WebSocket upgrade by returning `websocket(req; callbacks...)`.
`Facil.is_upgrade(req)` tells whether the request asks for one.

```julia
using Facil

serve("127.0.0.1", 8080) do req
    Facil.is_upgrade(req) || return Response(StatusCodes.NOT_FOUND, "WebSocket only")
    websocket(req;
              on_open = ws -> send(ws, "welcome"),
              on_message = (ws, msg) -> send(ws, msg),
              on_close = ws -> @info "closed" ws)
end
```

Callbacks, all optional:

| Callback | When |
|---|---|
| `on_open(ws)` | once, before any message |
| `on_message(ws, msg)` | per message; `msg` is a `String` (text) or `Vector{UInt8}` (binary) |
| `on_ready(ws)` | queued output has drained |
| `on_shutdown(ws)` | the server is stopping (a 1001 close follows) |
| `on_close(ws)` | once, after the connection is gone |

By default the callbacks run on the reactor thread, in order, and must not block.
`spawn = true` runs them on Julia tasks instead, still one at a time and in order
per connection.

- `send(ws, msg)` sends text for a `String`, binary for a `Vector{UInt8}`. It works
  from any thread and returns `false` once the connection is closing.
- `close(ws; code = 1000, reason = "")` starts the closing handshake.
- `ws.data` is free for the application.
- `max_message_size` (1 MiB): larger messages close the connection with 1009.
- Text messages that are not valid UTF-8 close it with 1007 unless `utf8_check = false`.
- `deflate = true` accepts permessage-deflate (without context takeover) when the
  client offers it.
- `subprotocol` is sent back as `Sec-WebSocket-Protocol`.
- `Facil.pending_bytes(ws)` is the number of bytes queued for the client.

To send one message to many clients, use [pub/sub](pubsub.md).
