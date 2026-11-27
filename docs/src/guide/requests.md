# [Reading requests](@id requests-guide)

This page shows how to read what the client sent: the method, the request
target (path and query), the headers and the protocol version. It also lists
what Facil answers by itself, before your handler is called. Request bodies
have their own page: [Request bodies and uploads](bodies.md).

## What a handler receives

A handler is called with one argument, a [`Request`](@ref)`{String}` from
HttpTypes. Facil builds it from the request head that facil.io parsed and, by
default, the whole body.

| Accessor | Type | What it is |
|---|---|---|
| [`method`](@ref)`(req)` | [`HttpMethod`](@ref) | `Methods.GET`, `Methods.POST`, ... or an extension method |
| [`uri`](@ref)`(req)` | [`Uri`](@ref) | the request target: [`path`](@ref)`(uri(req))` and [`query`](@ref)`(uri(req))` |
| [`version`](@ref)`(req)` | [`Version`](@ref) | `Versions.HTTP_11` or `Versions.HTTP_10` |
| [`headers`](@ref)`(req)` | [`HeaderMap`](@ref) | every header line, names lowercased |
| [`body`](@ref)`(req)` | `String` | the body bytes; `""` when there is none |
| [`extensions`](@ref)`(req)` | [`Extensions`](@ref) | per-request storage for your own values |

The same values are fields (`req.method`, `req.uri`, ...). The request belongs
to your handler: Facil keeps no reference to it, so you may change it, store it
or pass it to another task.

This server answers every request with a description of what it received:

```@eval
Main.example("requests_inspect.jl")
```

```sh
$ curl -X POST 'http://127.0.0.1:8080/users/7?page=2&q=a%20b' -A demo -H 'Accept: text/html' -H 'ACCEPT: application/json' -d hello
method: POST
path: /users/7
query: page=2&q=a%20b
version: HTTP/1.1
host: 127.0.0.1:8080
user-agent: demo
accept (all): text/html | application/json
headers: 6
body bytes: 5
```

## Method

`method(req)` is an [`HttpMethod`](@ref). Compare it with the constants in
[`Methods`](@ref) or with a string:

```@example requests
using Facil

req = Request(; method = "POST", uri = "/users/7?page=2&q=a%20b",
              headers = ["Host" => "example.com", "Accept" => "text/html", "ACCEPT" => "application/json"],
              body = "hello")

method(req) == Methods.POST, method(req) == "POST", is_safe(method(req))
```

The standard methods are `OPTIONS`, `GET`, `POST`, `PUT`, `DELETE`, `HEAD`,
`TRACE`, `CONNECT`, `PATCH` and `QUERY`. Any other valid token reaches your
handler as an extension method, so a request line `PURGE /cache HTTP/1.1` gives
`method(req) == "PURGE"`. Answer methods you do not support with 405 and an
`allow` header (see [Routing](routing.md)).

!!! note "HEAD"
    A HEAD request reaches your handler with `method(req) == Methods.HEAD`. Facil
    sends the status and headers your handler returns, with the `content-length`
    of the body, and drops the body. It does not turn HEAD into GET for you: a
    handler that branches on `Methods.GET` must also accept `Methods.HEAD` if
    you want HEAD answered like GET.

## Request target: path and query

`uri(req)` is the request target as a [`Uri`](@ref). For the usual origin-form
target (`/users/7?page=2`) it has a path and maybe a query:

```@example requests
u = uri(req)
path(u), query(u)
```

- [`path`](@ref)`(u)` is the part before `?`. It always starts with `/`
  (or is `*` for `OPTIONS *`).
- [`query`](@ref)`(u)` is the part after `?`, or `nothing` when the target has
  no query. A target that ends in a bare `?` also gives `nothing`, and a
  `#fragment` is dropped.
- A target in absolute form (`GET http://example.com/a?x=1 HTTP/1.1`, as proxies
  send) reaches your handler as `/a?x=1`: the scheme and host are dropped. Read
  the host from the `host` header.

!!! warning "Nothing is percent-decoded"
    Facil and HttpTypes hand you the path and query exactly as they were sent:
    `/caf%C3%A9` stays `/caf%C3%A9`, and `q=a%20b` stays `q=a%20b`. They are not
    split into parameters either. Decode what you use, after you have split it:
    decoding first would turn an encoded `/` (`%2F`) or `&` (`%26`) into a
    separator.

[`query_param`](@ref), [`query_params`](@ref) and [`decoded_path`](@ref)
split and decode them for you; [Query strings and forms](urls-and-forms.md)
has the details. [URIs.jl](https://github.com/JuliaWeb/URIs.jl) works as well:
`queryparams` splits and decodes a query string into a `Dict`, and
`unescapeuri` decodes one path segment:

```@eval
Main.example("requests_query.jl")
```

```sh
$ curl 'http://127.0.0.1:8080/caf%C3%A9/menu?name=Ada%20L&n=2'
hello Ada L
hello Ada L
segments: café, menu
```

`queryparams` keeps the last value of a repeated key and decodes `+` as a
space. Use `URIs.queryparampairs` when a key may repeat (`tag=a&tag=b`).

## Headers

`headers(req)` is a [`HeaderMap`](@ref): a multimap from [`HeaderName`](@ref)
to [`HeaderValue`](@ref). Names are stored lowercase, so lookups ignore case.
A key may be a string or one of the constants in [`header`](@ref), such as
`header.CONTENT_TYPE`; the constants skip the name check and compare as
integers.

```@example requests
h = headers(req)
h["host"], h[header.HOST], get(h, "X-Missing", nothing)
```

| Call | Result |
|---|---|
| `h[name]` | the first value; throws `KeyError` when absent |
| `get(h, name, default)` | the first value, or `default` |
| `haskey(h, name)` | whether the header was sent |
| [`get_all`](@ref)`(h, name)` | every value of a repeated header, in the order sent |
| `length(h)` | number of header lines; [`keys_len`](@ref)`(h)` counts distinct names |
| `for (name, value) in h` | every line, values of one name together |

A value is a [`HeaderValue`](@ref), not a `String`. It prints and interpolates
as its text and compares equal to a string; [`as_str`](@ref)`(v)` or
`String(v)` gives the `String` when you need one (to call `parse`,
`startswith`, a regex and so on). [`to_str`](@ref)`(v)` does the same but
throws when the value has bytes outside visible ASCII.

```@example requests
accept = get_all(h, "accept")
String.(accept), h["host"] == "example.com", startswith(as_str(h["accept"]), "text/")
```

Facil does not join repeated headers or split comma-separated lists, and it
does not parse `authorization` or `content-type` parameters. For cookies, use
[`cookies`](@ref)`(req)` (see [Cookies](cookies.md)). A request
with two `Accept` lines has two values under `accept`; `h["accept"]` is the
first.

## Version

`version(req)` is `Versions.HTTP_11` or `Versions.HTTP_10`. Facil speaks only
HTTP/1.x. A request from an HTTP/1.0 client is answered and its connection is
closed, unless the client asked for `Connection: keep-alive`. Versions are
ordered, so `version(req) < Versions.HTTP_11` tests for an old client.

## Storing your own values on a request

[`extensions`](@ref)`(req)` holds at most one value per type. Use it to hand
data from one layer of your code to the next (an authenticated user, a
request id) without a global:

```@example requests
struct RequestId
    value::String
end

insert!(extensions(req), RequestId("7f3a"))
get(extensions(req), RequestId).value
```

## What Facil answers without calling your handler

Some requests never reach the handler. Facil or facil.io answers them and, with
`verbose = true`, logs a line to stderr.

| Request | Answer | Connection |
|---|---|---|
| No `Host` header (HTTP/1.1 and HTTP/1.0 alike) | 400 | kept |
| A target or header name that HttpTypes rejects | 400 | kept |
| Request head over `max_header_size` (32 KiB), one header line over about 8 KiB, or more than 128 headers | 431 | closed |
| Declared body over `max_body_size` (50 MiB) | 413 | closed |
| Buffered body over `body_in_memory` (16 MiB) | 413 | closed |
| `before_body` returned `Reject(status)` | that status | closed |
| Request head still arriving after `header_timeout` (30 s) | 408 | closed |
| Connection silent for `timeout` (40 s), with or without part of a head | none | closed |
| A GET, HEAD or OPTIONS for a file in `public_folder` | the file | kept |

The error bodies are the reason phrase as `text/plain` (`Payload Too Large`).
You cannot change them from the handler; put a reverse proxy in front if you
need custom error pages for these cases.

The limits are keywords of [`serve!`](@ref):

```@eval
Main.example("requests_limits.jl")
```

`Expect: 100-continue` needs no code: Facil sends `100 Continue` as soon as it
has accepted the request head (after `max_body_size` and `before_body` have had
their say), then reads the body. A request it refuses gets its 413 instead, so
the client never sends the body.

!!! note "A client that goes away"
    Facil does not tell a running handler that its client has disconnected. The
    handler finishes and its response is dropped. Only streamed responses and
    event streams can see it, through `isopen`; see
    [Streaming responses](streaming.md).

## See also

- [Request bodies and uploads](bodies.md) for `before_body`, streaming and limits on bodies.
- [Routing](routing.md) for turning method and path into a handler.
- [JSON](json.md) for parsing JSON bodies.
- [Security notes](security.md) for choosing the limits.
- API: [`Request`](@ref), [`HeaderMap`](@ref), [`Uri`](@ref), [`serve!`](@ref).
