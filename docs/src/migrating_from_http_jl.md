# Migrating from HTTP.jl

HTTP.jl handlers take an `HTTP.Request` with string fields. Facil handlers take an
HttpTypes `Request{String}`, whose method, URI and headers are typed values. Each
handler needs a small rewrite. The HTTP.jl code below was run against HTTP.jl 2.16;
both versions of each example answer the same requests the same way.

## Names

| HTTP.jl | Facil |
|---|---|
| `HTTP.serve(f, host, port)` | `serve(f, host, port)` |
| `HTTP.serve!(f, host, port)`, `close(server)` | `serve!(f, host, port)`, `close(server)` |
| `req.method == "GET"` | `method(req) == Methods.GET` |
| `req.target` | `uri(req)`; `path(uri(req))`, `query(uri(req))` |
| `HTTP.queryparams(HTTP.URI(req.target))` | `URIs.queryparams(something(query(uri(req)), ""))` |
| `HTTP.header(req, "Content-Type", default)` | `get(headers(req), header.CONTENT_TYPE, default)` |
| `String(req.body)` | `body(req)` (already a `String`) |
| `HTTP.Response(200, ["K" => "v"], body)` | `Response(StatusCodes.OK, body; headers = ["K" => "v"])` |
| `HTTP.Response(404)` | `Response(StatusCodes.NOT_FOUND)` (`Response(404)` throws; `Response(404, "body")` works) |
| `HTTP.Router`, `HTTP.register!` | no router; branch on method and path |
| `HTTP.WebSockets.listen` / `HTTP.WebSockets.upgrade` | return `websocket(req; on_message = ...)` from the handler |
| stream handler (`HTTP.listen`, `HTTP.startwrite`) | return `stream(req) do io ... end` from the handler |
| `HTTP.Response` with a body built in memory, then sent | same; the body is sent without a copy, so do not change it afterwards |

Header names are case-insensitive in both. In Facil a header lookup by constant
(`header.CONTENT_TYPE`) is cheaper than by string.

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

```julia
using Facil, URIs

function app(req::Request)
    if method(req) == Methods.GET && path(uri(req)) == "/hello"
        name = get(queryparams(something(query(uri(req)), "")), "name", "world")
        Response(StatusCodes.OK, "hello $name"; headers = [header.CONTENT_TYPE => "text/plain"])
    elseif method(req) == Methods.POST && path(uri(req)) == "/echo"
        ct = something(get(headers(req), header.CONTENT_TYPE, nothing), hv"application/octet-stream")
        Response(StatusCodes.OK, body(req); headers = [header.CONTENT_TYPE => ct])
    else
        Response(StatusCodes.NOT_FOUND, "not found")
    end
end

serve(app, "127.0.0.1", 8080)
```

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

```julia
using Facil

serve("127.0.0.1", 8080) do req
    websocket(req; on_message = (ws, msg) -> send(ws, msg))
end
```

The Facil callbacks run on the reactor thread by default and must not block; pass
`spawn = true` to run them on tasks. See [WebSockets](guide/websockets.md).

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

```julia
using Facil

serve("127.0.0.1", 8080) do req
    stream(req; headers = [header.CONTENT_TYPE => "text/plain"]) do io
        for i in 1:3
            write(io, "line $i\n")
        end
    end
end
```

## Things that behave differently

- Facil handlers run on their own task (or inline on the reactor with
  `inline = true`). HTTP.jl 2.x runs handlers on the `:interactive` thread pool.
- Facil adds `date`, `last-modified`, `connection` and `content-length` to every
  response that lacks them, and always sets `content-length` itself.
- Facil answers HEAD itself (headers only) for whole responses.
- There is no HTTP client in Facil. Keep HTTP.jl (or Downloads.jl) for outgoing
  requests; both can run in the same process.
