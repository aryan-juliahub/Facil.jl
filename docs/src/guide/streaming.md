# Streaming responses

`stream(f, req)` returns a response whose body `f(io)` writes while it is being
sent. Use it when the length is not known in advance.

```julia
using Facil

serve("127.0.0.1", 8080) do req
    stream(req; headers = [header.CONTENT_TYPE => "text/plain"]) do io
        for i in 1:5
            write(io, "line $i\n")
            flush(io)
            Facil.sleep(0.1)
        end
    end
end
```

- HTTP/1.1 clients get `transfer-encoding: chunked` and keep the connection for
  the next request. HTTP/1.0 clients get a body ended by closing the connection.
- `write(io, x)` queues bytes; `flush(io)` sends them. Strings and byte vectors
  over 4 KiB are sent without a copy, so do not change a vector after writing it.
- On a task, `write` blocks while more than `high_water` bytes (1 MiB) wait for a
  slow client. `isopen(io)` turns false when the client has gone; `write` then throws.
- `f` runs on its own task for task-handler servers and on the reactor for inline
  servers; `spawn = true/false` overrides that. On the reactor `f` must not block.
- If `f` throws, the connection is closed so the client sees an incomplete body.
- A HEAD request gets the head only; `f` is not called.
- `compress = :gzip`, `:br` or `:zstd` compresses the stream; see
  [Compression](compression.md).
