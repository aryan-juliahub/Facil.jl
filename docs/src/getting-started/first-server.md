# [Your first server](@id first-server)

This page explains the model behind every Facil program: a request comes in,
your **handler** is called with it, and what the handler returns is sent back.
Read it once and the rest of the documentation will make sense.

## Five lines

```@eval
Main.example("hello.jl")
```

- `using Facil` brings in the server and the HTTP types. You do not need any
  other package.
- [`serve`](@ref) starts listening on `127.0.0.1:8080` and blocks until the
  server is stopped.
- The `do req ... end` block is the handler. Facil calls it once for every
  request, with a [`Request`](@ref).
- The handler returns a [`Response`](@ref): a status and a body.

`serve(handler, host, port)` is the same call written without `do`. Any
callable works as a handler: an anonymous function, a named function, or a
callable object.

## The request → handler → response model

```@raw html
<figure class="facil-diagram">
<svg viewBox="0 0 760 270" width="760" role="img" aria-label="Request lifecycle: the client sends a request; the reactor thread accepts the connection, parses the head and reads the body; the handler is called with a Request and returns a Response; the reactor writes the response back to the client.">
  <defs>
    <marker id="arrow-a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z"/></marker>
  </defs>
  <rect class="zone" x="150" y="20" width="330" height="230" rx="8"/>
  <text class="zone-label" x="162" y="40">REACTOR THREAD (facil.io, C)</text>
  <rect class="zone" x="520" y="20" width="225" height="230" rx="8"/>
  <text class="zone-label" x="532" y="40">YOUR CODE (Julia)</text>

  <rect class="box" x="15" y="110" width="100" height="50" rx="6"/>
  <text class="title" x="65" y="140" text-anchor="middle">Client</text>

  <rect class="box" x="170" y="58" width="290" height="44" rx="6"/>
  <text x="315" y="77" text-anchor="middle">1. accept, parse the request head</text>
  <text class="small" x="315" y="93" text-anchor="middle">limits checked: 400, 408, 431</text>

  <rect class="box" x="170" y="114" width="290" height="44" rx="6"/>
  <text x="315" y="133" text-anchor="middle">2. read the body (if any)</text>
  <text class="small" x="315" y="149" text-anchor="middle">before_body picks: Buffer, Stream, Spool, Reject</text>

  <rect class="box" x="170" y="190" width="290" height="44" rx="6"/>
  <text x="315" y="209" text-anchor="middle">4. write status, headers, body</text>
  <text class="small" x="315" y="225" text-anchor="middle">content-length and date added</text>

  <rect class="box" x="540" y="100" width="185" height="72" rx="6"/>
  <text class="title" x="632" y="124" text-anchor="middle">3. handler(req)</text>
  <text class="small" x="632" y="142" text-anchor="middle">on a worker task (default)</text>
  <text class="small" x="632" y="158" text-anchor="middle">or inline on the reactor</text>

  <path class="line" d="M115,125 C135,125 140,80 170,80" marker-end="url(#arrow-a)"/>
  <path class="line" d="M315,102 L315,114" marker-end="url(#arrow-a)"/>
  <path class="line" d="M460,136 L540,136" marker-end="url(#arrow-a)"/>
  <text class="small" x="500" y="128" text-anchor="middle">Request</text>
  <path class="line" d="M632,172 C632,212 520,212 460,212" marker-end="url(#arrow-a)"/>
  <text class="small" x="560" y="228" text-anchor="middle">Response</text>
  <path class="line" d="M170,212 C140,212 135,147 115,147" marker-end="url(#arrow-a)"/>
</svg>
<figcaption>One request. The connection then waits for the next one (keep-alive).</figcaption>
</figure>
```

1. **facil.io accepts the connection and parses the request head** on its
   event-loop thread, the *reactor*. A request that is malformed or over a
   limit is answered there (`400`, `408`, `431`) and never reaches your code.
2. **The body is read.** By default the whole body is collected in memory.
   The `before_body` option can stream it, spool it to disk or reject it; see
   [Request bodies and uploads](../guide/bodies.md).
3. **Your handler is called** with a `Request{String}`. By default it runs on
   a worker task, on one of Julia's threads, so it may take its time: query a
   database, read a file, sleep. With `inline = true` it runs on the reactor
   thread itself, which is faster for handlers that never wait.
   [Handlers and concurrency](../guide/handlers.md) explains the choice.
4. **The return value is written back**, and the connection waits for the
   client's next request.

There is no middleware stack, router or context object in between. A handler
is a function from a request to a response, which makes it easy to test: call
it. See [Testing](../guide/testing.md).

## What a handler receives

The request is an HttpTypes [`Request`](@ref). You read it with accessor
functions:

```@eval
Main.example("first_inspect.jl")
```

```sh
$ curl -X POST 'http://127.0.0.1:8080/orders/17?expand=items' -d '{"qty": 2}'
method: POST
path:   /orders/17
query:  expand=items
agent:  curl/8.7.1
body:   10 bytes
```

| Accessor | Gives | Type |
|:--|:--|:--|
| [`method`](@ref)`(req)` | the request method; compare with `Methods.GET`, `Methods.POST`, ... | [`HttpMethod`](@ref) |
| [`uri`](@ref)`(req)` | the request target | [`Uri`](@ref) |
| [`path`](@ref)`(uri(req))` | the path, as sent (not percent-decoded) | `String` |
| [`query`](@ref)`(uri(req))` | the query string after `?`, or `nothing` | `String` or `nothing` |
| [`headers`](@ref)`(req)` | the headers; names are case-insensitive | [`HeaderMap`](@ref) |
| [`body`](@ref)`(req)` | the body; `""` when there is none | `String` |
| [`version`](@ref)`(req)` | `Versions.HTTP_11` or `Versions.HTTP_10` | [`Version`](@ref) |

[Reading requests](../guide/requests.md) covers each of these in depth.

## What a handler returns

```@eval
Main.example("first_results.jl")
```

- **A `Response`**: `Response(status, body; headers = [...])`. The status is a
  constant from `StatusCodes` or an integer. The body is a `String`, a
  `Vector{UInt8}` or `nothing`.
- **A `String`**, as a shortcut for `200` with `text/plain; charset=utf-8`.
- **Something special**: [`stream`](@ref) for a body produced over time,
  [`sse`](@ref) for server-sent events, [`sendfile`](@ref) for a file,
  [`websocket`](@ref) to accept a WebSocket.

Facil sets `content-length` for you, and adds a `content-type` when a
non-empty body has none: `text/plain; charset=utf-8` for a `String`,
`application/octet-stream` for bytes.

If the handler throws (`/boom` above), the client gets
`500 Internal Server Error`, the error and its stack trace are printed to
stderr, and the server carries on. See [Errors and logging](../guide/errors.md).

!!! warning "`Response(404)` is an error"
    A single integer argument is ambiguous between a status and a body, so
    `Response(404)` throws an `ArgumentError`. Write
    `Response(StatusCodes.NOT_FOUND)` for a response without a body, or give
    both: `Response(404, "not found")`.

[Sending responses](../guide/responses.md) covers statuses, headers and bodies.

## `serve` and `serve!`

[`serve`](@ref) blocks, which is what the last line of a server program
wants. [`serve!`](@ref) takes the same arguments and returns a
[`Server`](@ref) immediately. Use it at the REPL, in tests, and when one
process runs several servers:

```@repl first
using Facil
server = serve!(req -> Response(StatusCodes.OK, "hello"), "127.0.0.1", 0)
port(server)   # port 0 asked for any free port; this is the one it got
isopen(server)
close(server)
```

Both accept keywords that set limits, timeouts, HTTPS, compression and more.
They are all listed in [Configuration](../reference/configuration.md).

## Next

- [Tutorial: a JSON API](tutorial.md) puts this together into a small service
  with routing, JSON, errors and a test.
- [Handlers and concurrency](../guide/handlers.md), if you want to understand
  the threading model before writing more.
