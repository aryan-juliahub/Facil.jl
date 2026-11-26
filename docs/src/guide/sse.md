# [Server-sent events](@id sse-guide)

This page shows how to push events to browsers and other clients over a
long-lived HTTP response with [`sse`](@ref): sending events, resuming after a
reconnect, keeping idle connections alive, and broadcasting to every open
stream.

Server-sent events (SSE) are one-way, server to client, and are read in the
browser with `EventSource`, which reconnects by itself. For two-way messages
use [WebSockets](websockets.md).

## A first event stream

The handler returns `sse(f, req)`. Facil answers with
`content-type: text/event-stream` and calls `f(s)` with an
[`SSEStream`](@ref) on a worker task. The connection stays open until `f`
returns or the client goes away.

```@eval
Main.example("sse_ticks.jl")
```

```sh
$ curl -N http://127.0.0.1:8080/events
retry: 2000

event: tick
id: 1
data: tick 1

event: tick
id: 2
data: tick 2
```

and so on to `tick 5` and a final `done` event. In a browser:

```js
const source = new EventSource("/events");
source.addEventListener("tick", (e) => console.log(e.lastEventId, e.data));
source.addEventListener("done", () => source.close());
```

`f` always runs on a task, also on a server with inline handlers, so it may
sleep and block. `sse` does not look at the request's `Accept` header: the
handler decides which paths are event streams.

## Sending events

[`write_event`](@ref) sends one event. All fields are optional, but an event
needs at least one of them:

| Keyword | Wire field | Meaning |
|---|---|---|
| `data` | `data:` | the payload; anything `string` accepts. Each line of a multi-line value becomes its own `data:` line, and the client joins them with newlines again |
| `event` | `event:` | the event type; without it the browser fires `message` |
| `id` | `id:` | the event id; the browser sends the last one it saw as `Last-Event-ID` when it reconnects |
| `retry` | `retry:` | how many milliseconds the client waits before reconnecting |

`write_event(s, data)` is short for `write_event(s; data)`.

`event` and `id` must be single lines; a line break in either throws an
`ArgumentError`. `data` is text: to send JSON, serialise it to a string first.

`write_event` returns `true` when the event was queued and `false` once the
client has gone or the stream is closed. It does not throw for a gone client,
so check the result (or `isopen(s)`) to stop a loop.

When more than `high_water` bytes (1 MiB by default, a keyword of
[`sse`](@ref)) wait for a slow client, `write_event` blocks until the client
has caught up.

## Resuming after a reconnect

When a connection drops, `EventSource` reconnects and sends the `id` of the
last event it received in a `Last-Event-ID` header.
[`last_event_id`](@ref)`(s)` returns it as a `String`, or `nothing` on a first
connection. The first example resumes from it:

```sh
$ curl -N -H 'Last-Event-ID: 3' http://127.0.0.1:8080/events
retry: 2000

event: tick
id: 4
data: tick 4
```

The id is whatever you sent, so treat it as untrusted input when it comes
back: parse it, and start from the beginning when it does not make sense.

## Keep-alives and broadcasting

An idle event stream sends nothing, and proxies and load balancers close
connections that are silent for long (often 60 seconds).
[`Facil.write_comment`](@ref)`(s, text)` sends a comment line, which clients
ignore, and keeps the connection warm. It returns `false` once the client has
gone, like `write_event`.

An `SSEStream` may be used from any task, so a set of open streams is all it
takes to broadcast. This server pushes every `POST /publish` body to every
client of `/feed`:

```@eval
Main.example("sse_feed.jl")
```

`wait(s)` blocks until the stream has closed, when the function has nothing
to do in between but wait.

!!! note "Facil's idle timeout does not apply"
    The server's `timeout` closes idle HTTP connections. After the event-stream
    head is sent the connection is no longer an HTTP connection and is not
    subject to it; keep-alives are for the benefit of proxies between you and
    the client.

## Ending a stream

- When `f` returns, Facil closes the connection. `EventSource` treats that as
  a dropped connection and **reconnects** after its retry delay. To stop for
  good, send a last event that tells the client to call `source.close()`, as
  the first example does with `done`.
- `close(s)` closes it from any task.
- When the client disconnects, `isopen(s)` turns `false`, `write_event` returns
  `false` and `wait(s)` returns. `f` is not interrupted: it must return by
  itself. A function that sleeps between events notices at its next write.
- If `f` throws, the error is logged and the connection is closed.

After an event stream the connection is not reused for HTTP requests.

## Limits

- Event streams are never compressed, whatever `compress` says.
- Each open stream holds a connection and a task. Browsers allow only six
  HTTP/1.1 connections per host, shared by all tabs; Facil has no HTTP/2 to
  lift that.
- [`Facil.live_streams`](@ref)`()` counts open event streams and streamed
  responses, for monitoring.

## See also

- [Streaming responses](streaming.md) for streams that are not events.
- [WebSockets](websockets.md) and [Pub/sub](pubsub.md) for two-way messages
  and broadcasts without Julia code per message.
- API: [`sse`](@ref), [`SSEStream`](@ref), [`write_event`](@ref),
  [`last_event_id`](@ref), [`Facil.write_comment`](@ref).
