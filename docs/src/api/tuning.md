# [Tuning and diagnostics](@id api-tuning)

This page documents the functions that report what a running process is doing
and the one garbage-collector knob Facil has. All are process-wide and cheap
enough to call from a metrics endpoint. The
[performance guide](../guide/performance.md) says when each one matters.

| Counter | Counts |
|:--|:--|
| [`Facil.connections(server)`](@ref Facil.connections) | open connections of one server |
| [`Facil.paused_requests()`](@ref Facil.paused_requests) | requests whose task handler has not finished |
| [`Facil.pending_bodies()`](@ref Facil.pending_bodies) | request bodies being received |
| [`Facil.pinned_bodies()`](@ref Facil.pinned_bodies) | response bodies not yet fully written |
| [`Facil.live_streams()`](@ref Facil.live_streams) | open streamed responses and event streams |
| [`Facil.open_websockets()`](@ref Facil.open_websockets) | open WebSocket connections |

```@docs
Facil.gc_headroom!
Facil.paused_requests
Facil.pinned_bodies
Facil.live_streams
```

A metrics endpoint built from the counters:

```@eval
Main.example("tuning_metrics.jl")
```
