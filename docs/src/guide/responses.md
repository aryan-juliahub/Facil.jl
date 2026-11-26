# [Sending responses](@id responses-guide)

This page shows what a handler may return and what Facil puts on the wire for
it: the status line, the headers Facil and facil.io add, and the body. Bodies
that are produced over time have their own pages:
[Streaming responses](streaming.md), [Server-sent events](sse.md) and
[Static files](static.md).

## What a handler may return

| The handler returns | The client gets |
|---|---|
| a [`Response`](@ref) with a `String` body | that status, those headers, the string's bytes |
| a `Response` with a `Vector{UInt8}` body | the same, with the bytes |
| a `Response` with body `nothing` (or an empty body) | status and headers, `content-length: 0` (no `content-length` for `1xx`, `204` and `304`) |
| a `String` | `200 OK`, `text/plain; charset=utf-8` |
| [`stream`](@ref)`(f, req)` | a body written piece by piece; see [Streaming responses](streaming.md) |
| [`sse`](@ref)`(f, req)` | an event stream; see [Server-sent events](sse.md) |
| [`sendfile`](@ref)`(path)` | a file; see [Static files](static.md) |
| [`websocket`](@ref)`(req; ...)` | a WebSocket upgrade; see [WebSockets](websockets.md) |
| anything else, or it throws | `500 Internal Server Error` |

Other `AbstractString` and `AbstractVector{UInt8}` bodies (a `SubString`, a
view) are accepted and copied into a `String` or `Vector{UInt8}` first.

One server showing most of these:

```@eval
Main.example("responses_kinds.jl")
```

## Building a `Response`

[`Response`](@ref) comes from HttpTypes. The forms you will use most:

```@example responses
using Facil

Response(StatusCodes.OK, "hello")                       # status and body
```

```@example responses
Response(StatusCodes.NO_CONTENT)                        # status only, body `nothing`
```

```@example responses
Response(StatusCodes.CREATED, "made";                   # with headers
         headers = [header.LOCATION => "/things/1", "x-request-id" => "42"])
```

The status is a [`StatusCode`](@ref). Use the constants in
[`StatusCodes`](@ref) (`StatusCodes.NOT_FOUND`), or an integer when a body
follows: `Response(404, "no such page")`.

!!! warning "`Response(404)` throws"
    A single integer argument is ambiguous (is it a status or a body?), so
    `Response(404)` throws an `ArgumentError`. Write
    `Response(StatusCodes.NOT_FOUND)` for a response with that status and no
    body. `Response("text")`, a single non-status argument, is a 200 with that
    body.

A response is mutable. Build it, then adjust it:

```@example responses
res = Response(StatusCodes.OK, "two cookies")
append!(headers(res), header.SET_COOKIE, "a=1; Path=/")
append!(headers(res), header.SET_COOKIE, "b=2; Path=/")
res.status = 202
res
```

## Status

Facil sends the status code you return, whatever it is from 100 to 999, with
its standard reason phrase: `canonical_reason(status)`, such as
`418 I'm a teapot`. A code that has no standard phrase (299, 599) is sent as
`299 Unknown`.

`1xx`, `204` and `304` responses never carry content. Facil sends them
without a body, without `content-length` and without a default
`content-type`, even if the `Response` was built with a body; the headers you
set (`etag`, `cache-control`, ...) are kept. Build them with
`Response(StatusCodes.NO_CONTENT)`.

Interim responses are not available to handlers: `100 Continue` is sent by
Facil (see [Reading requests](requests.md)), and there is no way to send
`103 Early Hints` before the final response.

## Headers

Pass `headers` as any iterable of `name => value` pairs, or change
[`headers`](@ref)`(res)` afterwards with `insert!` (replace), `append!` (add a
second line of the same name) and `delete!`. Names may be strings or the
constants in [`header`](@ref); they are validated and lowercased when the
response is built, and an invalid name or value throws there
(`InvalidHeaderName`, `InvalidHeaderValue`), inside your handler, where you can
see it.

Header names go out in lowercase. That is valid HTTP (names are
case-insensitive), but a client that compares names case-sensitively will miss
them.

Facil and facil.io complete the head:

| Header | Rule |
|---|---|
| `content-length` | always set by Facil from the body; a value you set is ignored |
| `transfer-encoding` | set by Facil for streamed responses; a value you set is ignored |
| `content-type` | if you set none and the body is not empty: `text/plain; charset=utf-8` for a string body, `application/octet-stream` for a byte body |
| `date` | added by facil.io when you set none (not on streamed responses) |
| `last-modified` | added by facil.io, with the current time, when you set none (not on streamed responses) |
| `connection` | `keep-alive` or `close`, added by facil.io when you set none |

!!! note "`last-modified` on dynamic responses"
    Every response that is not streamed gets `last-modified` set to the time it
    was sent unless you set the header yourself. A cache may use it for
    heuristic freshness. Set `cache-control` (for example `no-store`) on
    responses that must not be cached, or set `last-modified` to the real time
    your data changed.

To close the connection after a response, set `connection: close` on it.

## Bodies are sent without a copy

A `String` or `Vector{UInt8}` body is handed to the socket as it is: Facil
keeps the object alive until the last byte has been written and never copies
it. This is why large responses are cheap, and it has one rule:

!!! warning "Do not change a body after returning it"
    A `Vector{UInt8}` that you return (or write to a stream) may still be on its
    way to the client after your handler has returned. Do not write into it,
    `resize!` it or put it back into a buffer pool. Returning the same constant
    body from many requests at once is fine.

    Facil keeps the memory being sent alive, so this mistake changes the bytes
    the client receives but does not crash the process. On Julia 1.10,
    `resize!`, `append!` or `empty!` on a vector that is still being sent
    throws `cannot resize array with shared data`.

Strings are immutable, so this only concerns byte vectors.

## Redirects, errors and empty responses

A redirect is a status and a `location` header:

```@example responses
Response(StatusCodes.SEE_OTHER; headers = [header.LOCATION => "/login"])
```

For errors, return the status you mean. Nothing is added to a body you send,
so an API can use its own error format:

```@example responses
Response(StatusCodes.NOT_FOUND, """{"error":"no such user"}""";
         headers = [header.CONTENT_TYPE => "application/json"])
```

## When the handler fails

If the handler throws, returns something that is not in the table above, or
returns a response whose body Facil cannot send, the client gets a
`500 Internal Server Error` whose body is the text `Internal Server Error`
(`text/plain; charset=utf-8`).

The connection stays open for the next request. The error and its stack trace
are written to stderr, at most once per exception type every 10 seconds; see
[Errors and logging](errors.md). Nothing about the error is sent to the client.
To send your own error body, catch the exception in the handler and return a
response.

## HEAD requests

For a HEAD request Facil sends the head of whatever the handler returned and
leaves the body out; `content-length` is the length the body would have had.
The handler still runs and still builds the body, so check for
`Methods.HEAD` yourself when the body is expensive.

## See also

- [Streaming responses](streaming.md), [Server-sent events](sse.md),
  [Static files](static.md), [Compression](compression.md).
- [JSON](json.md) for JSON bodies.
- [Errors and logging](errors.md) for what is logged when a handler fails.
- API: [`Response`](@ref), [`StatusCode`](@ref), [`StatusCodes`](@ref),
  [`HeaderMap`](@ref), [`serve!`](@ref).
