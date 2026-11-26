# [Streaming responses](@id streaming-guide)

This page shows how to send a response body piece by piece with
[`stream`](@ref): for bodies whose length you do not know in advance, bodies
too large to build in memory, and output a client should see while it is
being produced. For a browser `EventSource`, use
[server-sent events](sse.md) instead.

## A first stream

The handler returns `stream(f, req)`. Facil sends the status line and headers
at once, then calls `f(io)` with a [`ResponseStream`](@ref). What `f` writes
to `io` goes to the client; when `f` returns, the body is complete.

```@eval
Main.example("streaming_lines.jl")
```

```sh
$ curl -N http://127.0.0.1:8080/
line 1
line 2
line 3
line 4
line 5
```

The lines appear one every 100 ms, not all at the end.

`stream` takes the response head as keywords:

| Keyword | Default | Meaning |
|---|---|---|
| `status` | `200` | a [`StatusCode`](@ref) or an integer |
| `headers` | none | `name => value` pairs, as for [`Response`](@ref) |
| `compress` | `:auto` | `:gzip`, `:br`, `:zstd`, `:auto` or `nothing`; see [Compression](compression.md) |
| `level` | `0` | compression level; 0 takes the default |
| `spawn` | `nothing` | where `f` runs; see [below](#Where-the-function-runs) |
| `high_water` | 1 MiB | queued bytes above which a write waits for the client |

If you set no `content-type`, a stream is sent as `application/octet-stream`.
A `content-length` header is ignored: a stream never has one.

## What goes on the wire

- An **HTTP/1.1** client gets `transfer-encoding: chunked`. After the last
  chunk the connection is kept for the next request, like any other response.
- An **HTTP/1.0** client cannot read chunks. It gets the bytes as they are and
  the end of the body is marked by closing the connection.
- A **HEAD** request gets the head only; `f` is not called.

Each `write` call becomes one chunk. `print(io, "n=", 12)` is two writes and
two chunks, and writing a single byte allocates a small vector. Build each
piece as one string or one byte vector (an `IOBuffer` and `take!` work well)
and write that:

```@eval
Main.example("streaming_export.jl")
```

## Writing

A [`ResponseStream`](@ref) is an `IO` you can only write to.

- `write(io, x)` takes a `String` or a `Vector{UInt8}` (other strings and
  single bytes are converted). `print` and `println` work through it.
- Buffers of 4 KiB or less are copied. Larger ones are sent **without a copy**:
  do not change a `Vector{UInt8}` after writing it. `take!(buf)` gives you a
  fresh vector each time, so the pattern above is safe.
- `flush(io)` pushes what is queued to the socket now. Without it, a task's
  writes are sent when 64 KiB are queued or when the task next yields or
  blocks, whichever comes first, so a burst of small writes leaves in few
  packets. Call `flush` when the client should see a piece immediately and
  your code is about to compute, not wait.
- `close(io)` ends the body early. You rarely need it: returning from `f` does
  the same.

## Slow clients and back-pressure

When `f` runs on a task, a `write` that leaves more than `high_water` bytes
queued for the client blocks until the client has read most of them (a quarter
of `high_water` remains). Your producer therefore runs at the client's speed
and memory stays bounded by `high_water` plus one write. Lower it for many
concurrent slow clients, raise it for few fast ones.

On the reactor (see the next section) a write never blocks; the bytes are
queued without limit. Only stream from the reactor what you would be willing
to hold in memory.

A client that stops reading entirely is disconnected by the server's
`max_pending_output` limit (see [Configuration](../reference/configuration.md)).

## When the client goes away

`isopen(io)` turns `false` once the client has disconnected, and the next
`write` throws a `Base.IOError`. Facil catches that error for you: the function
is simply ended and nothing is logged. So a plain loop of writes stops by
itself. Check `isopen(io)` in loops that do expensive work between writes, as
the export example does, so that the work stops too.

This is the only place where a handler can notice a disconnect: a handler that
returns an ordinary `Response` is never told.

## When the function throws

If `f` throws anything else, Facil logs the error and closes the connection
without the final chunk. The status line (usually 200) has already been sent
and cannot be changed, so a broken connection is the only signal left: an
HTTP/1.1 client reports an incomplete response. Do the work that can fail
(opening the file, running the query) before you return `stream(...)`, while
you can still answer with a 4xx or 5xx.

## Where the function runs

By default `f` runs where the server's handlers run:

- On a server with **task handlers** (`inline = false`, the default with more
  than one Julia thread), `f` runs on a worker task. It may block, sleep and do
  I/O; writes apply back-pressure.
- On a server with **inline handlers**, `f` runs on the reactor thread. It
  must not block: every other connection on that thread waits for it.

`spawn = true` or `spawn = false` overrides this for one response. A short
stream from memory on a task-handler server can use `spawn = false` to skip
the hand-off; a slow stream on an inline server needs `spawn = true`.

See [Handlers and concurrency](handlers.md) for the two kinds of handler.

## See also

- [Server-sent events](sse.md) for streams a browser reads with `EventSource`.
- [Compression](compression.md) for compressed streams.
- [Static files](static.md) for sending files (do not stream a file by hand;
  `sendfile` is faster and handles ranges).
- API: [`stream`](@ref), [`ResponseStream`](@ref), [`Facil.wait_drain`](@ref),
  [`Facil.live_streams`](@ref).
