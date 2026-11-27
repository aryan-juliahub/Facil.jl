# [Migrating from HTTP.jl](@id from-http-jl)

This page is for readers with an HTTP.jl server. It maps HTTP.jl's server API
to Facil's, shows three handlers before and after, and lists what Facil does
not replace. HTTP.jl is not a dependency of Facil, and the two can be loaded in
the same process.

The HTTP.jl code on this page is for comparison. It follows HTTP.jl's
documented server API and is not run by this documentation's tests, so check
it against the HTTP.jl version you use; every Facil example is run.

## What changes

- **Types.** An HTTP.jl handler takes an `HTTP.Request` whose method and target
  are strings and whose body is bytes. A Facil handler takes an HttpTypes
  [`Request`](@ref)`{String}`: the method is an [`HttpMethod`](@ref), the
  target a parsed [`Uri`](@ref), headers a [`HeaderMap`](@ref), the body a
  `String`.
- **One handler style.** HTTP.jl has request handlers (`HTTP.serve`) and stream
  handlers (`HTTP.listen`). Facil has one kind: a function that returns a
  response. Streaming, server-sent events, files and WebSockets are special
  responses returned from that same function.
- **Server only.** Facil has no HTTP client. Keep HTTP.jl or `Downloads` for
  outgoing requests.
- **No router.** Branch on method and path (see [Routing](routing.md)).
  Query strings, form bodies and cookies have helpers: see
  [Query strings and forms](urls-and-forms.md) and [Cookies](cookies.md).

## Names

| HTTP.jl | Facil |
|---|---|
| `HTTP.serve(f, host, port)` | [`serve`](@ref)`(f, host, port)` |
| `HTTP.serve!(f, host, port)` | [`serve!`](@ref)`(f, host, port)` |
| `close(server)`, `wait(server)`, `isopen(server)` | the same; also `close(server; grace = seconds)` |
| `req.method == "GET"` | `method(req) == Methods.GET` (comparing with `"GET"` also works) |
| `req.target` | `uri(req)`; `path(uri(req))` and `query(uri(req))` |
| `HTTP.URI(req.target).path` | `path(uri(req))` |
| `HTTP.queryparams(HTTP.URI(req.target))` | [`query_params`](@ref)`(req)` (pairs, repeats kept; `Dict(query_params(req))` for a `Dict`), [`query_param`](@ref)`(req, name)` for one |
| `URIs.unescapeuri(s)`, `URIs.escapeuri(s)` | [`percent_decode`](@ref)`(s)`, [`percent_encode`](@ref)`(s)` |
| `HTTP.header(req, "Content-Type", default)` | `get(headers(req), header.CONTENT_TYPE, default)` |
| `HTTP.hasheader(req, "X-Id")` | `haskey(headers(req), "x-id")` |
| `HTTP.headers(req, "Accept")` (all values) | `get_all(headers(req), header.ACCEPT)` |
| `req.headers` (vector of pairs) | `headers(req)`, a [`HeaderMap`](@ref) that iterates as `name => value` |
| `String(req.body)` | `body(req)` (already a `String`) |
| `req.context[:key]` | `extensions(req)`, a map keyed by type |
| `HTTP.Response(200, ["K" => "v"], body)` | `Response(StatusCodes.OK, body; headers = ["K" => "v"])` |
| `HTTP.Response(404)` | `Response(StatusCodes.NOT_FOUND)` |
| `HTTP.Response(404, "not found")` | `Response(404, "not found")` or `Response(StatusCodes.NOT_FOUND, "not found")` |
| `res.status`, `res.headers`, `res.body` | `status(res)`, `headers(res)`, `body(res)` |
| `HTTP.setheader(res, "K" => "v")` | `insert!(headers(res), "k", "v")`; `append!` adds a second value |
| `HTTP.Router`, `HTTP.register!` | not available; see [Routing](routing.md) |
| `HTTP.listen` stream handler, `HTTP.startwrite`, `write(http, x)` | return [`stream`](@ref)`(req) do io ... end` |
| `HTTP.WebSockets.listen`, `HTTP.WebSockets.upgrade` | return [`websocket`](@ref)`(req; on_message = ...)` |
| event streams written by hand in a stream handler | return [`sse`](@ref)`(req) do s ... end` |
| `HTTP.serve(...; sslconfig = ...)` | `serve(...; tls = TLSConfig(cert, key))` |
| `HTTP.get`, `HTTP.post`, `HTTP.request` | not available (no client) |
| `HTTP.Cookies.cookies(req)` | [`cookies`](@ref)`(req)` |
| `HTTP.Cookies.Cookie(...)`, `HTTP.Cookies.addcookie!(res, c)` | [`set_cookie!`](@ref)`(res, name, value; ...)`, [`delete_cookie!`](@ref) |

Three rules explain most compile errors after a port:

1. `Response(404)` throws an `ArgumentError`, because a lone integer could be
   a status or a body. Write `Response(StatusCodes.NOT_FOUND)`. With a body, an
   integer status is accepted: `Response(404, "not found")`.
2. Headers are a keyword, not the second positional argument:
   `Response(status, body; headers = [...])`.
3. Header values are [`HeaderValue`](@ref)s. They compare equal to strings, but
   to call string functions on one, convert it with `as_str(value)`.

Header names are case-insensitive in both packages. In Facil a lookup by
constant (`header.CONTENT_TYPE`) is cheaper than a lookup by string.

## Request and response

HTTP.jl:

```julia
using HTTP

function app(req::HTTP.Request)
    uri = HTTP.URI(req.target)
    if req.method == "GET" && uri.path == "/hello"
        name = get(HTTP.queryparams(uri), "name", "world")
        HTTP.Response(200, ["Content-Type" => "text/plain"], "hello $name")
    elseif req.method == "POST" && uri.path == "/echo"
        ct = HTTP.header(req, "Content-Type", "application/octet-stream")
        HTTP.Response(200, ["Content-Type" => ct], req.body)
    else
        HTTP.Response(404, "not found")
    end
end

HTTP.serve(app, "127.0.0.1", 8080)
```

Facil:

```@eval
Main.example("httpjl_app.jl")
```

[`query_param`](@ref) decodes the query like `HTTP.queryparams` does (`+` is
a space, `%XX` escapes are decoded) and returns the first value of the name.
URIs.jl still works too: Facil's names do not clash with its exports.

## WebSocket echo

HTTP.jl:

```julia
using HTTP

HTTP.WebSockets.listen("127.0.0.1", 8080) do ws
    for msg in ws
        HTTP.WebSockets.send(ws, msg)
    end
end
```

Facil:

```@eval
Main.example("httpjl_ws.jl")
```

The shape differs. HTTP.jl gives you a loop on a task per connection. Facil
calls `on_message` per message, by default on the reactor thread, where it
must not block; pass `spawn = true` to run callbacks on tasks. State that
lived in local variables of the loop moves to `ws.data`. See
[WebSockets](websockets.md).

## Streaming a response

HTTP.jl:

```julia
using HTTP

HTTP.listen("127.0.0.1", 8080) do http
    HTTP.startread(http)
    HTTP.setstatus(http, 200)
    HTTP.setheader(http, "Content-Type" => "text/plain")
    HTTP.startwrite(http)
    for i in 1:3
        write(http, "line $i\n")
    end
end
```

Facil:

```@eval
Main.example("httpjl_stream.jl")
```

Status and headers are arguments of [`stream`](@ref); the function receives
an `IO` to write the body to. HTTP/1.1 clients get a chunked body and the
connection stays open for the next request. See
[Streaming responses](streaming.md).

## Things that behave differently

- **Where handlers run.** Facil runs each handler on a task of its worker pool
  (several Julia threads), or on the reactor thread with `inline = true`.
  Handlers run in parallel: guard shared state. Start Julia with threads
  (`julia -t 4`); with one thread, handlers run inline on the reactor and must
  not block.
- **Headers Facil adds.** Every response gets `content-length` (or chunked
  framing), `date`, `connection`, and `last-modified` set to the current time
  when you set none. A body without a `content-type` gets
  `text/plain; charset=utf-8` (string) or `application/octet-stream` (bytes).
- **HEAD.** Facil answers HEAD with the headers of the response your handler
  returns and no body. You do not need a separate branch.
- **Bodies are not copied.** A `Vector{UInt8}` you return is sent from your
  array. Do not change it afterwards.
- **Errors.** An uncaught exception gives a plain `500` and a log entry on
  stderr; an error type is logged at most once per call site every 10 seconds. See
  [Errors and logging](errors.md).
- **Request bodies.** By default the whole body is read before the handler
  runs (up to `body_in_memory`, 16 MiB). To read uploads as they arrive, or to
  refuse them early, use `before_body`; see [Request bodies](bodies.md).
- **Limits.** Defaults differ: 32 KiB of headers, 50 MiB bodies, a 30-second
  header timeout. See [Configuration](../reference/configuration.md).
- **Shutdown.** `serve` drains on SIGTERM. See [Graceful shutdown](shutdown.md).
- **Platforms.** Facil runs on Linux and macOS (Windows through WSL2) and
  speaks HTTP/1.1 only.

## A migration checklist

1. Replace `using HTTP` with `using Facil` in server code; keep HTTP.jl where
   you make outgoing requests, as `import HTTP` to avoid name clashes.
2. Rewrite handler signatures and accessors with the table above.
3. Replace `HTTP.Router` with branches or a small route table.
4. Move stream handlers to `stream`, WebSocket loops to callbacks.
5. Review every global your handlers touch for thread safety.
6. Run your tests against a server on port 0 (see
   [Testing a Facil app](testing.md)).
7. Read [Limits](../reference/limits.md) for what Facil does not do.

## See also

- [Coming from Node.js and Express](from-node.md).
- [HttpTypes reference](../api/httptypes/index.md).
- [Handlers and concurrency](handlers.md).
