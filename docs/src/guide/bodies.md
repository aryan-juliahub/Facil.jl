# Request bodies

By default a request body is read into memory and the handler gets it as
`body(req)`. The `before_body` keyword of `serve`/`serve!` changes that per
request. It is called with a [`RequestHead`](@ref) when a body starts, and
returns one of:

| Result | What happens |
|---|---|
| `Buffer()` | The default. The whole body is read into memory; `body(req)` is a `String`. Bodies over `body_in_memory` (16 MiB) get a 413. |
| `Stream()` | The body is not kept. Read it with `body_chunks(req)` or `body_stream(req)`. A task handler starts as soon as the head arrives. |
| `Stream(on_chunk)` | Each piece is passed to `on_chunk(bytes)` on the reactor thread as it arrives; the handler runs after the body ends. `on_chunk` must not block. |
| `Spool()` | The body is written to an unlinked temporary file; `body_stream(req)` is an `IOStream` at position 0. |
| `Reject(status)` | The server answers `status` (4xx or 5xx) without reading the body and closes the connection. |

`RequestHead` has `method(head)`, `uri(head)`, `version(head)`, `headers(head)`
and `head.content_length` (`-1` for a chunked body).

## Streaming an upload

```julia
using Facil

function choose(head)
    path(uri(head)) == "/upload" && return Stream()
    head.content_length > 1_000_000 && return Reject(413)
    Buffer()
end

serve("127.0.0.1", 8080; before_body = choose) do req
    if path(uri(req)) == "/upload"
        n = 0
        for chunk in body_chunks(req)
            n += length(chunk)
        end
        Response(StatusCodes.OK, "streamed $n bytes")
    else
        Response(StatusCodes.OK, "buffered $(sizeof(body(req))) bytes")
    end
end
```

Reading `body_chunks(req)` in a task handler hands every chunk from the reactor
to the task and back, which costs about five times Node's CPU per upload
(scoreboard row 25, an approved exception). When the work per chunk does not
block (counting, hashing, writing to a buffer), use `Stream(on_chunk)` instead:
the chunks are handled on the reactor and the handler runs once with the result.
This beats Node.

```julia
using Facil

const RECEIVED = Threads.Atomic{Int}(0)

serve("127.0.0.1", 8080; inline = true,
      before_body = head -> Stream(c -> Threads.atomic_add!(RECEIVED, length(c)))) do req
    Response(StatusCodes.OK, "received $(RECEIVED[]) bytes so far")
end
```

`before_body` creates a new `on_chunk` for each request, so per-request state can
live in its closure.

`max_body_size` (default 50 MiB) is checked first: a larger declared body gets a
413 before `before_body` runs.

## Spooling to disk

```julia
using Facil

serve("127.0.0.1", 8080; before_body = head -> Spool(), max_body_size = 1 << 30) do req
    io = body_stream(req)
    n = 0
    while !eof(io)
        n += length(read(io, 65536))
    end
    Response(StatusCodes.OK, "spooled $n bytes")
end
```
