# API

Facil exports the names below and re-exports every exported name of HttpTypes
(`Request`, `Response`, `StatusCodes`, `Methods`, `header`, ...). Those are
documented on the [HttpTypes page](httptypes.md#HttpTypes-API).

```@docs
Facil
```

## Servers

```@docs
serve
serve!
Server
Base.close(::Server)
```

## Request bodies

```@docs
RequestHead
Buffer
Stream
Spool
Reject
BodyStream
body_stream
body_chunks
```

## Static files

```@docs
sendfile
```

## Streaming responses

```@docs
stream
ResponseStream
Base.close(::ResponseStream)
```

## Server-sent events

```@docs
sse
SSEStream
write_event
last_event_id
Base.close(::SSEStream)
```

## WebSockets

```@docs
websocket
WebSocket
send(::WebSocket, ::Union{String,Vector{UInt8}})
Base.close(::WebSocket)
```

## Pub/sub

```@docs
subscribe
unsubscribe
publish
```

## Timers

```@docs
every
```

## Compression

```@docs
CompressOptions
```

## TLS

```@docs
TLSConfig
TLSError
reload!
```

## Not exported

These are public but not exported; call them as `Facil.name`.

```@docs
Facil.sleep
Facil.Timer
Facil.gc_headroom!
Facil.is_upgrade
Facil.WebSocketUpgrade
Facil.pending_bytes
Facil.open_websockets
Facil.slow_subscribers!
Facil.websocket_compressor!
Facil.Subscription
Facil.write_comment
Facil.wait_drain
Facil.live_streams
Facil.drain_server!
Facil.ischunked
Facil.BodyAborted
Facil.register_mime!
Facil.mime_type
Facil.compressible_type
Facil.compress_response
Facil.gzip
Facil.zstd
Facil.brotli
Facil.pinned_bodies
Facil.paused_requests
```
