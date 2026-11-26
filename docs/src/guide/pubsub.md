# [Pub/sub](@id pubsub-guide)

This page shows how to send one message to many receivers with channels:
[`publish`](@ref) on one side, [`subscribe`](@ref) on the other. Use it to
broadcast to WebSocket clients and to connect parts of your program without
keeping lists of connections.

## The model

A channel is a name (any string). `publish(channel, msg)` delivers `msg` to
everything subscribed to that exact name at that moment. Nothing is stored: a
subscriber that arrives later does not see earlier messages. There are no
patterns or wildcards.

There are two kinds of subscriber:

| | `subscribe(ws, channel)` | `subscribe(f, channel)` |
|---|---|---|
| Receiver | a WebSocket client | your function `f(msg::String)` |
| Julia code per message | none | one call |
| Runs on | the reactor, in C | the reactor thread (or a task with `spawn = true`) |
| Ends | with the connection, or `unsubscribe(ws, channel)` | `unsubscribe(sub)` / `close(sub)` |
| Returns | `true`, or `false` if `ws` is not open | a [`Facil.Subscription`](@ref) |

Pub/sub is **process-local**. Messages do not reach other processes or other
machines; facil.io's Redis engine is not wrapped. To span processes, publish
from a subscriber to your own broker client.

## A chat room

Every client subscribes its own connection in `on_open`; what one client sends
is published to all. A POST endpoint publishes to the same channel, and a
function subscriber keeps the last 100 messages.

```@eval
Main.example("pubsub_chat.jl")
```

```sh
$ curl -X POST -d 'lunch' http://127.0.0.1:8080/announce     # every chat client receives "announcement: lunch"
$ curl http://127.0.0.1:8080/history
hi from a
announcement: lunch
```

Things to notice:

- A client receives its own messages too, because its connection is subscribed
  like any other.
- `publish` is called from a WebSocket callback (reactor thread), from a task
  handler (worker task) and could be called from any other thread. Delivery
  always happens on the reactor.
- `HISTORY` needs no lock here: the function subscriber runs on the reactor
  thread, one message at a time. The `/history` request reads it from a worker
  task, though; a program that cares about a consistent snapshot must guard
  both sides with a lock (and keep the critical section short, since one side
  is the reactor).

## Broadcasting to WebSocket clients

`subscribe(ws, channel)` is the efficient way to fan out. The WebSocket frame
is built once per message and shared by every subscriber; no Julia code runs
per client.

- By default a message is sent as a text frame when it is valid UTF-8 and as a
  binary frame otherwise. `binary = true` or `binary = false` forces one.
- Subscribing a connection twice to the same channel is a no-op.
- Call it from `on_open` or later. Before the connection is open it returns
  `false` and does nothing.
- The subscription ends when the connection closes. You do not need to
  unsubscribe in `on_close`.

A ticker that publishes from a timer, with a way for clients to opt out:

```@eval
Main.example("pubsub_ticker.jl")
```

## Subscribing a function

`subscribe(f, channel)` calls `f(msg)` for every message, with the message as a
`String` (also when bytes were published).

By default `f` runs on the reactor thread, in publishing order, and must not
block. With `spawn = true` every call runs on its own Julia task: `f` may then
block, but calls can overlap and order is not kept.

If `f` throws, the error is logged to stderr and the subscription stays active.

Keep the returned [`Facil.Subscription`](@ref) if you want to end it:
`unsubscribe(sub)` or `close(sub)`. After that no new call to `f` starts;
`isopen(sub)` is `false`. Subscriptions that are still open when the process
exits are ended for you.

`subscribe(f, channel)` and `publish` start the reactor if it is not running
yet, so they work before the first `serve!`.

## Publishing

`publish(channel, msg)` takes a `String` or bytes (`Vector{UInt8}`), returns
`nothing` and never blocks. It works from any thread. Messages published from
one thread arrive in the order they were published.

Publishing to a channel nobody subscribes to is not an error; the message is
dropped.

## Slow subscribers

A broadcast is written to each subscribed connection's output queue. A client
that reads slower than you publish would make its queue grow without bound.
[`Facil.slow_subscribers!`](@ref) sets what happens to a WebSocket subscriber
with more than `limit` unsent bytes:

| `policy` | Effect on the slow client |
|---|---|
| `:close` (default) | The connection is closed. |
| `:drop_newest` | The new message is skipped for this client. |
| `:drop_oldest` | Its oldest unsent broadcasts are discarded to make room. |
| `:ignore` | Nothing; the queue grows. |

`limit = 0` turns the check off, which is the state at start-up. The setting is
process-wide and applies to every channel. [`Facil.slow_subscriber_stats`](@ref)`()`
returns three counters since the process started: `dropped` (messages
skipped or discarded), `closed` (connections closed) and `events` (times a
subscriber was found over the limit).
The ticker example above sets `:drop_newest` at 1 MiB and reports the counters
at `/stats`.

The policy covers `subscribe(ws, channel)` broadcasts only. Messages you send
with `send(ws, msg)` are always queued; see
[WebSockets](websockets.md#Limits-and-checks).

## See also

- [WebSockets](websockets.md) for the connection side.
- [Server-sent events](sse.md) for one-way streams over plain HTTP.
- [Timers](timers.md) for `every`.
- API: [`publish`](@ref), [`subscribe`](@ref), [`unsubscribe`](@ref),
  [`Facil.Subscription`](@ref), [`Facil.slow_subscribers!`](@ref).
