# [Routing](@id routing-guide)

This page shows how to send requests to different code by method and path.
Facil has no router of its own: a handler is one function from a request to a
response, and routing is ordinary Julia inside it. The page starts with plain
branching, builds a small router with path parameters, and ends with what is
known about router packages.

## Branching on method and path

For a handful of routes, compare [`method`](@ref)`(req)` and
[`path`](@ref)`(uri(req))` and branch:

```@eval
Main.example("routing_branch.jl")
```

```sh
$ curl http://127.0.0.1:8080/users/7
user 7
$ curl -i -X DELETE http://127.0.0.1:8080/users/7 | head -1
HTTP/1.1 405 Method Not Allowed
```

What to keep in mind when you route by hand:

- `path(uri(req))` has no query string, so `/?x=1` matches `"/"`. It is **not
  percent-decoded** and not normalised: `/users/7/`, `//users/7` and
  `/users/%37` are three different strings, none equal to `/users/7`. Decide
  whether trailing slashes matter and decode segments after you split them
  (see [Reading requests](requests.md)).
- Compare methods with the constants in [`Methods`](@ref). `HEAD` is its own
  method: the app above answers `HEAD /` with 405. Accept it wherever you
  accept `GET` if you want it answered (Facil drops the body for you).
- Tell "no such path" (404) from "wrong method for this path" (405 with an
  `allow` header). Clients and proxies treat them differently.
- A `String` return value is a 200 `text/plain` response; anything that is not
  a response gives a 500 (see [Sending responses](responses.md)).

For exact paths, a `Dict` is a constant-time router:

```@example routing
using Facil

const ROUTES = Dict(
    (Methods.GET, "/") => req -> Response(StatusCodes.OK, "home\n"),
    (Methods.GET, "/health") => req -> Response(StatusCodes.OK, "ok\n"),
    (Methods.POST, "/jobs") => req -> Response(StatusCodes.ACCEPTED),
)

function app(req)
    handler = get(ROUTES, (method(req), path(uri(req))), nothing)
    handler === nothing ? Response(StatusCodes.NOT_FOUND, "not found\n") : handler(req)
end

status(app(Request(Methods.GET, "/health"))), status(app(Request(Methods.GET, "/nope")))
```

A handler is a plain function of a [`Request`](@ref), so you can call it with
a request you build, as the last line does. [Testing](testing.md) builds on
that.

## A small router with path parameters

When routes have parameters (`/users/:id`), about forty lines give you a
router: a list of routes, each a method, a pattern split into segments, and a
function that receives the request and the captured parameters.

```@eval
Main.example("routing_router.jl", "router")
```

A `Router` is callable, so it is the handler:

```@eval
Main.example("routing_router.jl", "routes")
```

```sh
$ curl http://127.0.0.1:8080/users/1
ada
$ curl http://127.0.0.1:8080/users/2/posts/5
post 5 of user 2
$ curl -i -X PUT http://127.0.0.1:8080/users/2 | grep -i -e '^HTTP' -e allow
HTTP/1.1 405 Method Not Allowed
allow:GET, DELETE
```

What this router does and does not do:

- Routes are tried in the order they were added; the first whose segments
  and method match wins. Put literal routes before parameter routes that would
  also match (`/users/me` before `/users/:id`).
- Empty segments are dropped, so `/users/` and `/users` are the same route.
- Parameters are `String`s, still percent-encoded. Parse and validate them in
  the route (`tryparse(Int, params["id"])`).
- A path that matches under another method gives 405 with an `allow` header
  listing the methods that would work.
- It is a linear scan, which is fine for tens of routes. For hundreds, index
  the routes by first segment or by segment count.
- There are no wildcards, no typed parameters and no middleware. Add what you
  need; the next section shows middleware.

## Wrapping handlers (middleware)

Because a handler is a function, anything that takes a handler and returns a
handler is middleware. This one adds a header to every response and answers
`HEAD` through the `GET` routes:

```@example routing
function with_defaults(handler)
    function (req)
        if method(req) == Methods.HEAD
            req.method = Methods.GET
        end
        res = handler(req)
        res isa Response && insert!(headers(res), "x-content-type-options", "nosniff")
        res
    end
end

wrapped = with_defaults(app)
res = wrapped(Request(Methods.HEAD, "/health"))
status(res), headers(res)["x-content-type-options"]
```

Give `serve` the wrapped function: `serve(with_defaults(app), "127.0.0.1", 8080)`.
Check `res isa Response` before touching headers, because a handler may also
return a `String`.

## Router packages

Facil handlers take an HttpTypes [`Request`](@ref), not an `HTTP.Request`, and
no registered router package is built on HttpTypes yet. The web frameworks and
routers in Julia's General registry that we looked at (Oxygen, Genie, Mux,
Bukdu, Bonsai, Merly, Dance, Pages and Toolips, in November 2026) all depend on
HTTP.jl and route `HTTP.Request` values through HTTP.jl's server, as does
`HTTP.Router` itself. None of them works as a Facil handler today, and Facil
does not ship an adapter.

If you are moving an application from HTTP.jl, see
[Coming from HTTP.jl](from-http-jl.md) for how its `Router` usage maps to the
approach on this page.

## See also

- [Reading requests](requests.md) for paths, queries and headers.
- [JSON](json.md) and the [tutorial](../getting-started/tutorial.md) for a
  routed JSON API.
- [Testing](testing.md) for calling handlers without a server.
- API: [`method`](@ref), [`path`](@ref), [`Methods`](@ref),
  [`StatusCodes`](@ref).
