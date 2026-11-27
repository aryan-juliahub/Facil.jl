# [Errors and logging](@id errors-guide)

This page shows what Facil does when your code throws, what it writes to
stderr and when, and how to wrap a handler to produce your own error responses
and an access log.

## When a handler throws

If the handler throws, the client gets a `500`:

```text
HTTP/1.1 500 Internal Server Error
content-type: text/plain; charset=utf-8
content-length: 21

Internal Server Error
```

The exception and its stack trace are written to stderr, the connection stays
usable and the server keeps running. The response never contains the error
message.

A handler that returns something that is neither a [`Response`](@ref) nor a
string gives the same `500`, with a log line that names the type.

```@eval
Main.example("errors_default.jl")
```

After three requests to `/throw` and one to `/number`, stderr holds (stack
traces left out):

```text
Facil: uncaught error in a request handler: database unavailable
Facil: uncaught error in a request handler's result: the handler returned a Int64; it must return a Response or a String
```

## How Facil logs

Facil writes its own messages straight to file descriptor 2 (stderr). They do
not go through Julia's `Logging` system, so a custom logger does not see them
and cannot format them. Every line starts with `Facil: `.

**Errors are rate-limited by exception type and call site.** The first error
of a type (`ErrorException`, `KeyError`, ...) thrown from a given place is
logged with its stack trace. Further errors of the same type *from the same
place* within the next 10 seconds are only counted. The next one logged after
that carries a note such as `(41 more like it in the last 10 s)`.

"The same place" means the same innermost four frames of the stack trace, so
two different `error("...")` calls are logged separately, and so is one
function failing when called from two different places. In the example above
the three `/throw` requests produce one log entry. The limit does not look at
the message: do not rely on Facil's log to see every failure; wrap your
handler as shown below.

## What each kind of callback does on error

| Where the error is thrown | Client sees | Logged as `Facil: uncaught error in ...` | Afterwards |
|---|---|---|---|
| Handler | `500` | `a request handler` | connection kept |
| Handler returns a wrong type | `500` | `a request handler's result` | connection kept |
| `before_body` function | `500` | `before_body` | connection closed |
| `Stream(on_chunk)` callback | `500` after the upload | `a Stream on_chunk callback` | later chunks are not passed on; connection closed |
| Function given to [`stream`](@ref) | the body stops; the connection is closed without the final chunk | `a streamed response` | the status line (`200`) was already sent |
| Function given to [`sse`](@ref) | the event stream ends | `an SSE handler` | connection closed |
| WebSocket callback | nothing | `a WebSocket callback` | connection stays open |
| `subscribe(f, channel)` callback | nothing | `a subscription callback` | subscription stays active |
| Timer callback | nothing | `a timer callback` | the timer stops |

Two cases are not logged because they are the client's doing: a
[`Facil.BodyAborted`](@ref) from reading a request body whose client went away,
and an `IOError` from writing to a streamed response whose client went away.

With a streamed response the status has already been sent when your function
runs, so an error cannot become a `500`. Closing the connection without the
terminating chunk is how the client learns that the body is incomplete.

## Your own error responses and access log

A handler is a function, so a wrapper is a function that takes a handler and
returns one. This program maps errors to responses itself, logs unexpected ones
in full through Julia's logging, and prints one access-log line per request:

```@eval
Main.example("errors_wrapper.jl")
```

```sh
$ curl -i http://127.0.0.1:8080/users/2
HTTP/1.1 404 Not Found
...
no such user
$ curl http://127.0.0.1:8080/bug
internal error, request id 1
```

and on the server's terminal:

```text
GET /users/2 404 0.1 ms
┌ Error: request 1 failed
│   method = Methods.GET
│   target = "/bug"
│   exception =
│    ArgumentError: invalid base 10 digit 'n' in "not a number"
│    Stacktrace:
│      ...
GET /bug 500 12.3 ms
```

Notes on writing such wrappers:

- Order matters. `with_access_log(with_errors(app))` logs the status the client
  really got, because the error wrapper has already turned exceptions into
  responses.
- A handler may return a plain string. Wrappers that look at the result must
  allow for that (`res isa Response`).
- For [`stream`](@ref), [`sse`](@ref), [`sendfile`](@ref) and
  [`websocket`](@ref) results, the wrapper returns before the body is written.
  It sees the status but not how many bytes were sent or how long that took,
  and a `try`/`catch` around the handler does not catch errors thrown later by
  the stream function. Catch those inside the function you pass to `stream` or
  `sse`.
- Logging from a task handler may block; that is fine. In an inline handler
  (`inline = true`) every write to a terminal or file happens on the reactor
  thread and delays all its connections. Keep logging out of inline handlers,
  or hand lines to a task through a `Channel`.

## Server start-up and rejected requests: `verbose`

`verbose = true` on [`serve`](@ref) or [`serve!`](@ref) makes the server log
what it does on its own:

```text
Facil: listening on http://127.0.0.1:8080 (reactor threads 1, Julia threads 4, handlers on tasks; limits: header 32 KiB, body 50 MiB, in memory 16 MiB, idle timeout 40 s, header timeout 30 s, pending output 16 MiB)
```

and also:

- requests refused by `before_body` or by `body_in_memory`, with method, target
  and status;
- a note when Julia has one thread and handlers therefore run inline;
- the start of a graceful close and of a signal drain.

It is not an access log: accepted requests are not printed.

Setting the environment variable `FACIL_VERBOSE=1` before starting Julia turns
on facil.io's own informational messages as well (`INFO: Listening on port
8080`, worker and capacity details). They come from the C library and are
useful when you suspect a problem below Facil.

## Errors before the handler

Some requests are answered without your code running, so there is nothing to
catch: malformed requests (`400`), a missing `Host` header (`400`), a request
head that is too large (`431`) or too slow (`408`), a body over a limit
(`413`). These responses have a short plain-text body with the reason phrase.
See [Limits](../reference/limits.md) for the full list.

## Start-up errors

Errors in how you call Facil are thrown to you, not logged:

- `serve!` throws an `ArgumentError` for an option out of range, and a
  `SystemError` when it cannot listen (address in use, permission denied).
- [`TLSConfig`](@ref) and [`reload!`](@ref) throw `ArgumentError` or
  [`TLSError`](@ref); see [TLS](tls.md#Errors-show-up-early).

## A client that goes away

A handler is not stopped when its client disconnects. The handler runs to
the end and its response is discarded, unless a task handler checks
[`isconnected`](@ref) or registers [`on_disconnect`](@ref) and stops itself.
Bound the work a single request can cause either way.

Long-lived responses do notice: for [`stream`](@ref), `isopen(io)` turns
`false` and `write` throws an `IOError`; for [`sse`](@ref), `isopen(s)` turns
`false` and [`write_event`](@ref) returns `false`; a streamed request body
throws [`Facil.BodyAborted`](@ref) when read.

## See also

- [Testing a Facil app](testing.md).
- [Security notes](security.md).
- [FAQ and troubleshooting](../reference/faq.md).
