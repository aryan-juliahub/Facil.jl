# Routing

Facil has no router. A handler is a function from a `Request` to a `Response`, so
routing is ordinary Julia: compare `method(req)` and `path(uri(req))` and branch.

```julia
using Facil

function app(req)
    m, p = method(req), path(uri(req))
    if m == Methods.GET && p == "/"
        Response(StatusCodes.OK, "home")
    elseif m == Methods.GET && startswith(p, "/users/")
        id = tryparse(Int, chopprefix(p, "/users/"))
        id === nothing && return Response(StatusCodes.BAD_REQUEST, "bad id")
        Response(StatusCodes.OK, "user $id")
    elseif p == "/" || startswith(p, "/users/")
        Response(StatusCodes.METHOD_NOT_ALLOWED, "only GET"; headers = [header.ALLOW => "GET"])
    else
        Response(StatusCodes.NOT_FOUND, "not found")
    end
end

serve(app, "127.0.0.1", 8080)
```

- `method(req)` is an `HttpMethod`. Compare it with the constants in `Methods`
  (`Methods.GET`, `Methods.POST`, ...).
- `path(uri(req))` is the path without the query string. It is not percent-decoded.
- A handler may also return a plain `String`; it is sent as `200 text/plain`.
- A handler that throws gives the client a 500, and the error is logged to stderr
  (once per error type every 10 seconds).

For many routes, a `Dict{Tuple{HttpMethod,String},Function}` or a chain of
`startswith` checks works well. HTTP.jl's `Router` has no equivalent here; see
[Migrating from HTTP.jl](../migrating_from_http_jl.md).
