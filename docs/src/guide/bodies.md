# [Request bodies and uploads](@id bodies-guide)

This page shows how to receive request bodies: whole in memory (the default),
streamed while they arrive, spooled to disk, or refused before a byte of them
is read. It covers the `before_body` keyword of [`serve!`](@ref), the limits on
body size, and what each choice costs.

## The default: the whole body in memory

Without any option, Facil reads the body into memory and calls your handler
once it is complete. [`body`](@ref)`(req)` is a `String` holding the bytes
exactly as sent (binary uploads too: use `codeunits(body(req))` for the bytes).
A request without a body has `body(req) == ""`.

Two limits apply, both keywords of [`serve!`](@ref):

| Keyword | Default | Applies to | Over the limit |
|---|---|---|---|
| `max_body_size` | 50 MiB | every body, whatever `before_body` chooses | 413, connection closed |
| `body_in_memory` | 16 MiB | bodies received with [`Buffer`](@ref) | 413, connection closed |

A body with a `content-length` over a limit is refused from its head, before
the client uploads it. A chunked body has no declared length, so it is refused
when the bytes received pass the limit.

## Choosing per request with `before_body`

`before_body` is a function you give to [`serve!`](@ref). Facil calls it on the
reactor thread when the head of a request with a body is complete, with a
[`RequestHead`](@ref), and it returns what to do with the body:

| Result | The body | The handler |
|---|---|---|
| [`Buffer`](@ref)`()` | read into memory (the default) | runs when the body is complete; `body(req)` has it |
| [`Stream`](@ref)`()` | handed over piece by piece, never held whole | reads it with [`body_chunks`](@ref) or [`body_stream`](@ref) |
| [`Stream`](@ref)`(on_chunk)` | each piece is passed to `on_chunk(bytes)` on the reactor thread | runs when the body is complete |
| [`Spool`](@ref)`()` | written to an unlinked temporary file | reads it from `body_stream(req)`, an `IOStream` |
| [`Reject`](@ref)`(status)` | not read | not called; the client gets `status` and the connection is closed |

A [`RequestHead`](@ref) has the same accessors as a request, minus the body:
`method(head)`, `uri(head)`, `version(head)` and `headers(head)`. It also has
`head.content_length`, the declared length in bytes, or `-1` for a chunked
body ([`Facil.ischunked`](@ref)`(head)` tests for that).

`before_body` runs on the reactor thread, so it must not block: decide from the
head alone (path, method, `content-length`, `content-type`, an
`authorization` header) and return. It is not called for requests without a
body. If it throws or returns anything else, the client gets a 500.

This server streams `/upload`, spools `/import`, and buffers everything else
up to 100 kB:

```@eval
Main.example("bodies_choose.jl")
```

```sh
$ curl -d abc http://127.0.0.1:8080/notes
buffered 3 bytes
$ head -c 3000000 /dev/zero | curl --data-binary @- http://127.0.0.1:8080/upload
streamed 3000000 bytes
```

## Rejecting early

[`Reject`](@ref)`(status)` answers before the body is read. The status must be
a 4xx or 5xx; the default is 413. Use it for uploads that are too large for
their route, requests without credentials, or methods a route does not take.
The client gets the reason phrase as a `text/plain` body.

Because the unread body is still on its way, Facil closes the connection after
the answer. A client that sent `Expect: 100-continue` (curl does for large
uploads) has not started sending and sees the rejection at once; other clients
may see the connection reset while they are still sending.

`max_body_size` is checked first: a body over it is refused with 413 and
`before_body` is not called. Raise `max_body_size` for servers that take large
uploads on some routes, and use `before_body` to keep the other routes small,
as the example above does.

## Streaming an upload to the handler

With [`Stream`](@ref)`()` the body is never held whole. The handler reads it:

- [`body_chunks`](@ref)`(req)` iterates over the pieces as `Vector{UInt8}`, in
  arrival order. The pieces are as large as the socket reads were; do not
  rely on their size.
- [`body_stream`](@ref)`(req)` is a [`BodyStream`](@ref), an `IO`: `read`,
  `readbytes!`, `readline`, `readavailable`, `eof` and anything built on them
  work.

`body(req)` is `""` for a streamed request.

```@eval
Main.example("bodies_stream_io.jl")
```

How this behaves depends on where the handler runs (see
[Handlers and concurrency](handlers.md)):

- A **task handler** (`inline = false`, the default with more than one Julia
  thread) starts as soon as the head has arrived and reads the body while it
  uploads. Reading blocks the handler's task until the next piece is there.
  When more than `high_water` bytes (4 MiB by default, `Stream(; high_water)`)
  wait unread, Facil stops reading the socket until the handler has caught up
  to half of that, so a fast client cannot fill memory faster than the handler
  drains it.
- An **inline handler** (`inline = true`, or Julia started with one thread)
  runs only when the whole body has been queued in memory. Nothing is saved
  compared with `Buffer()`; use `Stream(on_chunk)` or `Spool()` instead.

If the handler returns without reading everything, the rest of the body is read
and discarded so the connection can serve its next request.

If the client disconnects before the body is complete, the next read throws
[`Facil.BodyAborted`](@ref). An uncaught `BodyAborted` ends the handler quietly
(it is not logged, and there is no one to answer). Catch it when you have
something to clean up, as the example does.

## Handling chunks on the reactor with `on_chunk`

`Stream(on_chunk)` calls `on_chunk(bytes)` for each piece on the reactor
thread, as it arrives, and runs the handler once the body has ended. No piece
crosses threads, which makes this the cheapest way to consume an upload.

The rules for `on_chunk`:

- `bytes` is valid only during the call. It is a view of the read buffer:
  copy what you keep.
- It must not block (no file or network I/O that can stall, no
  `Facil.sleep`, no contended locks): the reactor serves every connection.
- If it throws, the error is logged and the client gets a 500 when the body
  ends; the handler is not called.

`before_body` runs once per request, so the function it returns can carry
per-request state. This server hashes each upload without holding it:

```@eval
Main.example("bodies_on_chunk.jl")
```

The handler receives a request with an empty body; it finds the state the
callback built through something both can see (here a table keyed by a request
header).

## Spooling to disk

[`Spool`](@ref)`()` writes the body to a temporary file as it arrives and gives
the handler an `IOStream` positioned at the start. The file is already
unlinked, so it disappears when the stream is closed or the process exits,
whatever happens to the handler. Use it for bodies that are too large for
memory and that the handler wants to read at its own pace, or more than once
(`seekstart(io)`).

The file is created by `mktemp`, in the directory `tempdir()` names (set
`TMPDIR` to move it). The reactor thread does the writing; on a slow disk that
delays other connections. If writing fails (disk full), the client gets a 500
and the handler is not called.

## Which one to use

| You have | Use |
|---|---|
| JSON, forms, anything small | the default, `Buffer()`, with `body_in_memory` set to what you expect |
| Large uploads that you process as bytes pass (hash, count, parse incrementally) without blocking | `Stream(on_chunk)` |
| Large uploads that you forward or process with blocking I/O | `Stream()` with a task handler |
| Large uploads that you need as a file, or need to read twice | `Spool()` |
| Uploads you can refuse from the head | `Reject(status)` |

The cost of `Stream()` with a task handler is the hand-off: every piece goes
from the reactor thread to the handler's task. On the benchmark that measures
it (a 1 MB upload streamed through a task, scoreboard row 25) Facil does 0.21×
the requests per CPU-second of Node.js, one of the approved exceptions listed
on the [benchmarks page](../reference/benchmarks.md). Most of that CPU is
Julia's idle worker threads spinning between hand-offs; starting Julia with
`JULIA_THREAD_SLEEP_THRESHOLD=0` gives 0.71×. Buffered uploads of the
same size are faster than Node (rows A12c, 24a, 24b), and `Stream(on_chunk)`
has no hand-off at all.

## See also

- [Reading requests](requests.md) for the rest of the request.
- [Handlers and concurrency](handlers.md) for task and inline handlers.
- [Security notes](security.md) for choosing limits against hostile clients.
- API: [`Buffer`](@ref), [`Stream`](@ref), [`Spool`](@ref), [`Reject`](@ref),
  [`RequestHead`](@ref), [`BodyStream`](@ref), [`body_stream`](@ref),
  [`body_chunks`](@ref), [`Facil.BodyAborted`](@ref).
