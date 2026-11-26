# [WebSockets](@id websockets-guide)

This page shows how to accept WebSocket connections, where your callbacks run,
how to send and close, and which limits and options apply. To send one message
to many clients, continue with [Pub/sub](pubsub.md).

## Accept a connection

A WebSocket connection starts as an HTTP request that asks for an upgrade. It
reaches your handler like any other request. To accept it, return
[`websocket`](@ref)`(req; callbacks...)` from the handler.

```@eval
Main.example("ws_echo.jl")
```

[`Facil.is_upgrade`](@ref)`(req)` tells you whether a request asks for a
WebSocket. Use it to answer ordinary requests on the same path, as above. If you
return `websocket(req; ...)` for a request that is not a valid upgrade, the
client gets a `400` and no callback runs.

`websocket` returns a [`Facil.WebSocketUpgrade`](@ref). Return each one once; do
not keep it for a later request.

## Callbacks

All callbacks are optional keywords of [`websocket`](@ref). Each receives the
connection as a [`WebSocket`](@ref).

| Callback | Called |
|---|---|
| `on_open(ws)` | once, before any message |
| `on_message(ws, msg)` | for each message: `msg` is a `String` for a text message, a `Vector{UInt8}` for a binary one |
| `on_ready(ws)` | each time everything queued for the client has been written to the socket |
| `on_shutdown(ws)` | when its server closes or drains, or the process exits, with the connection still open; a `1001` close follows |
| `on_close(ws)` | once, after the connection is gone |

Fragmented messages are joined before `on_message` runs. Ping and pong frames
are handled for you.

A callback that throws is logged to stderr (see [Errors and logging](errors.md))
and the connection stays open.

!!! note "What a closing server does to WebSockets"
    `close(server)`, `close(server; grace)` and the drain on SIGTERM call
    `on_shutdown` for each of that server's open WebSockets, send the client a
    `1001` (going away) close frame and close the connection; `on_close` runs
    last. `on_shutdown` is the last chance to `send`. With `spawn = true` the
    callback runs on a task and may start after the close frame has gone out,
    so a message it sends can be lost (see
    [Shutting down](shutdown.md#Long-lived-connections)).

## Where callbacks run

By default callbacks run **on the reactor thread**, one at a time and in order.
This is the fast path: an echo costs no task switch. The price is the usual
rule for the reactor: a callback must not block. No `Facil.sleep`, no locks
held for long, no blocking I/O. A callback that blocks stalls every connection
on that reactor thread, HTTP requests included.

Pass `spawn = true` to run a connection's callbacks **on Julia tasks**. They
still run one at a time and in order for that connection, but they may block,
and other connections are served meanwhile:

```@eval
Main.example("ws_tasks.jl")
```

With `spawn = true`, messages that arrive while a callback runs wait in a
queue. When more than 16 MiB of messages wait, Facil stops reading from that
client until the queue is back under 4 MiB, so a fast sender cannot fill your
memory.

| | default | `spawn = true` |
|---|---|---|
| Callbacks run on | the reactor thread | Julia tasks |
| Order per connection | kept | kept |
| May block | no | yes |
| Cost per message | none | a task hand-off |
| `borrow = true` | honoured | ignored (messages are copied) |

## Send, close and connection state

- [`send`](@ref)`(ws, msg)` sends one message: text for a `String`, binary for a
  `Vector{UInt8}`. It works from any thread and any task, not only inside
  callbacks. It returns `true` when the message was queued and `false` (sending
  nothing) once the connection is closing or closed.
- `close(ws; code = 1000, reason = "")` starts the closing handshake. The socket
  closes when the client answers, or after 3 seconds. Valid codes are 1000,
  1001–1014 and 3000–4999; anything else throws an `ArgumentError`. Reasons
  longer than 123 bytes are cut. `on_close` runs afterwards.
- `isopen(ws)` is `true` between `on_open` and the close.
- `ws.data` is a field for your own use. It starts as `nothing`.
- [`Facil.pending_bytes`](@ref)`(ws)` is the number of bytes queued for the
  client that the socket has not taken yet.
- [`Facil.open_websockets`](@ref)`()` counts the connections that are open in
  the whole process.

## Per-connection state

Keep what you know about a connection in `ws.data`. Set it in `on_open`; it is
still there in `on_close`.

```@eval
Main.example("ws_state.jl")
```

A session with a command-line client such as `websocat ws://127.0.0.1:8080/ws`
(lines you type are marked `>`):

```text
< hello guest; send `/name NAME` to rename yourself
> /name ada
< you are now ada
> hi
< ada #2: hi
```

To reach connections from outside their callbacks (a timer, another request),
either keep them in a collection of your own, guarded by a lock and cleaned up
in `on_close`, or use [pub/sub](pubsub.md), which needs neither.

## Limits and checks

- **Message size.** A message larger than `max_message_size` bytes (default
  1 MiB) closes the connection with code `1009`.
- **UTF-8.** A text message that is not valid UTF-8 closes the connection with
  code `1007`. Pass `utf8_check = false` to skip the check; `msg` may then be an
  invalid `String`.
- **Slow clients.** `send` never blocks. Bytes the socket does not take at once
  are queued in memory. Watch [`Facil.pending_bytes`](@ref) or use `on_ready` if
  you produce data faster than a client may read it. For broadcasts, see
  [`Facil.slow_subscribers!`](@ref).
- **Idle connections.** A WebSocket connection that has been silent for 40
  seconds is sent a ping, so idle connections stay open and dead ones are
  found. The interval is fixed; the server's `timeout` keyword does not change
  it.

## Options

| Keyword | Default | Effect |
|---|---|---|
| `max_message_size` | `1048576` | Largest message accepted, in bytes. Must be positive. |
| `utf8_check` | `true` | Check text messages for valid UTF-8. |
| `spawn` | `false` | Run callbacks on Julia tasks instead of the reactor thread. |
| `borrow` | `false` | Pass binary messages as a view of facil.io's buffer instead of a copy. |
| `deflate` | `false` | Accept permessage-deflate when the client offers it. |
| `subprotocol` | `nothing` | Value sent back as `Sec-WebSocket-Protocol`. |

**`borrow = true`** saves a copy per binary message. The array you get is valid
only until `on_message` returns. Do not store it, send it to another task or
capture it in a closure; `copy` it if you need it later. Text messages are
always copied.

**`deflate = true`** accepts the permessage-deflate extension, without context
takeover. Messages under 128 bytes, and messages that do not shrink, are sent
uncompressed. An integer from 1 to 9 instead of `true` also sets the compression
level, for the whole process. [`Facil.websocket_compressor!`](@ref) chooses the
codec.

**`subprotocol`** is not negotiated for you. Read the client's offer from the
request (`get(headers(req), header.SEC_WEBSOCKET_PROTOCOL, nothing)`) and pass
the one you choose.

## What is not there

- No WebSocket client.
- No per-message access to frames, and no way to send a ping yourself.
- The client's address is not available.
- HTTP/1.1 upgrades only (no WebSockets over HTTP/2).

## See also

- [Pub/sub](pubsub.md) for broadcasts.
- [Testing a Facil app](testing.md#Testing-WebSocket-code).
- [TLS](tls.md): `wss://` needs nothing extra, serve with `tls`.
- API: [`websocket`](@ref), [`WebSocket`](@ref), [`send`](@ref),
  [`Facil.is_upgrade`](@ref), [`Facil.pending_bytes`](@ref).
