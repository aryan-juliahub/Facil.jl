# [WebSockets and pub/sub](@id api-websockets)

This page documents WebSocket connections and the process-local pub/sub that
broadcasts to them. A handler accepts a WebSocket by returning
[`websocket`](@ref); from then on your callbacks receive a [`WebSocket`](@ref).
The [WebSockets guide](../guide/websockets.md) and the
[pub/sub guide](../guide/pubsub.md) have complete programs.

## Accepting a connection

```@docs
websocket
Facil.is_upgrade
Facil.WebSocketUpgrade
```

## Using a connection

```@docs
WebSocket
send(::WebSocket, ::Union{String,Vector{UInt8}})
Base.close(::WebSocket)
Facil.pending_bytes
```

## Pub/sub

`publish` reaches two kinds of subscriber: WebSocket clients, which receive
the message without any Julia code running, and Julia callbacks.

```@docs
publish
subscribe(::WebSocket, ::AbstractString)
unsubscribe(::WebSocket, ::AbstractString)
subscribe(::Any, ::AbstractString)
unsubscribe(::Facil.Subscription)
Facil.Subscription
```

## Slow clients and settings

```@docs
Facil.slow_subscribers!
Facil.slow_subscriber_stats
Facil.websocket_compressor!
Facil.open_websockets
```
