# Server-sent events

`sse(f, req)` answers with `text/event-stream`. `f(s)` runs on its own task and
the connection stays open until `f` returns or the client goes away.

```julia
using Facil

serve("127.0.0.1", 8080) do req
    path(uri(req)) == "/events" || return Response(StatusCodes.NOT_FOUND, "")
    sse(req) do s
        n = something(tryparse(Int, something(last_event_id(s), "0")), 0)
        for _ in 1:3
            n += 1
            write_event(s; event = "tick", data = "tick $n", id = n)
            Facil.sleep(0.2)
        end
    end
end
```

- `write_event(s; data, event, id, retry)` sends one event and returns `false`
  once the client has gone. `write_event(s, data)` is the short form.
- `last_event_id(s)` is the client's `Last-Event-ID` header, or `nothing`.
- `Facil.write_comment(s, text)` sends a comment line, useful as a keep-alive.
- `isopen(s)` turns false when the client has gone; `wait(s)` blocks until then.
- After an SSE response the connection is no longer HTTP: it is closed when `f`
  returns.
