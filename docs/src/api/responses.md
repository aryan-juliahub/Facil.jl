# [Responses](@id api-responses)

This page documents the functions that build a response other than a plain
[`Response`](@ref): streamed bodies, event streams, files, and compression.
A plain response is `Response(status, body; headers)`, documented on the
[HttpTypes messages page](httptypes/messages.md); what Facil does with it is
described under [`serve!`](@ref) and in the [responses guide](../guide/responses.md).

| A handler returns | The client gets |
|:--|:--|
| `Response(StatusCodes.OK, "text")` | a response with that body |
| `"text"` | `200`, `text/plain; charset=utf-8` |
| [`stream`](@ref)`(f, req)` | a body written piece by piece by `f` |
| [`sse`](@ref)`(f, req)` | an event stream fed by `f` |
| [`sendfile`](@ref)`(path)` | a file, with caching and range support |
| [`websocket`](@ref)`(req; ...)` | a WebSocket connection ([WebSockets](websockets.md)) |

## Streamed responses

```@docs
stream
ResponseStream
Base.flush(::ResponseStream)
Base.close(::ResponseStream)
Facil.wait_drain
```

## Server-sent events

```@docs
sse
SSEStream
write_event
Facil.write_comment
last_event_id
Base.close(::SSEStream)
```

## Files

```@docs
sendfile
Facil.mime_type
Facil.register_mime!
```

## Compression

```@docs
CompressOptions
Facil.compressible_type
Facil.compress_response
Facil.gzip
Facil.zstd
Facil.brotli
```
