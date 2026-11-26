# [Request bodies](@id api-requests)

This page documents how a server receives request bodies. A handler gets a
[`Request`](@ref)`{String}`, a type from HttpTypes; its accessors
([`method`](@ref), [`uri`](@ref), [`headers`](@ref), [`body`](@ref) and the
rest) are on the [HttpTypes messages page](httptypes/messages.md). What is
documented here is Facil's part: choosing, per request, where the body goes.

The `before_body` keyword of [`serve!`](@ref) is a function that receives a
[`RequestHead`](@ref) and returns one of four values:

| `before_body` returns | The body | The handler reads it with |
|:--|:--|:--|
| [`Buffer`](@ref)`()` (default) | is read into memory | `body(req)`, a `String` |
| [`Stream`](@ref)`()` | is handed over as it arrives | [`body_chunks`](@ref) or [`body_stream`](@ref) |
| [`Stream`](@ref)`(on_chunk)` | is passed to `on_chunk` piece by piece | nothing; `on_chunk` saw it |
| [`Spool`](@ref)`()` | is written to a temporary file | [`body_stream`](@ref), an `IOStream` |
| [`Reject`](@ref)`(status)` | is not read | the handler is not called |

The [request bodies guide](../guide/bodies.md) shows complete programs for each.

## Choosing where a body goes

```@docs
RequestHead
Facil.ischunked
Buffer
Stream
Spool
Reject
```

## Reading a body

```@docs
body_stream
body_chunks
BodyStream
Facil.BodyAborted
```

## Counters

```@docs
Facil.pending_bodies
```
