# [Query strings, paths and forms](@id urls-guide)

This page shows how to decode what is percent-encoded in a request: the
query string, the path, and `application/x-www-form-urlencoded` bodies (what
an HTML `<form method="post">` sends). The helpers follow the same rules as
the WHATWG URL standard behind Node's `URLSearchParams` and Rust's
`form_urlencoded`.

| You want | Call | Result |
|---|---|---|
| one query parameter | [`query_param`](@ref)`(req, "name"; default = nothing)` | the first value, decoded, or `default` |
| every query parameter | [`query_params`](@ref)`(req)` | `Vector{Pair{String,String}}`, in order, repeats kept |
| the decoded path | [`decoded_path`](@ref)`(req)` | `String`, or `nothing` if it cannot be decoded safely |
| a form body | [`parse_form`](@ref)`(req)` | `Vector{Pair{String,String}}`, like `query_params` |
| any query-like string | [`parse_query`](@ref)`(s)` | the same pairs, from a `String` |
| decode or encode one piece | [`percent_decode`](@ref)`(s)`, [`percent_encode`](@ref)`(s)` | `String` |

The raw values are still there: `path(uri(req))` and `query(uri(req))` are
what the client sent (see [Reading requests](requests.md)).

## Query parameters

```@eval
Main.example("urls_query.jl")
```

```sh
$ curl 'http://127.0.0.1:8080/caf%C3%A9/menu?name=Ada+L&tag=a&tag=b%26c'
path: /café/menu
hello Ada L
tags: a, b&c
```

`query_params` splits the query on `&`, splits each piece at its first `=`,
turns `+` into a space and percent-decodes both sides. A piece without `=` has
the value `""`, empty pieces are skipped, and a name that appears twice gives
two pairs:

```@example urls
using Facil

req = Request(; uri = "/search?q=julia+web&tag=a&tag=b&flag&empty=")
query_params(req)
```

The result is a vector so that nothing is lost. Turn it into what you need:

```@example urls
q = query_params(req)
Dict(q)                                  # last value of each name wins
```

```@example urls
[v for (k, v) in q if k == "tag"]       # every value of one name
```

`query_param(req, name)` is the first value of `name` (the same as
`URLSearchParams.get`). It decodes only the names until it finds a match, so it
is the cheaper call when you need one or two parameters. Convert numbers
yourself and decide what a bad value means:

```@example urls
page = something(tryparse(Int, query_param(req, "page"; default = "1")), 1)
```

## Paths

`decoded_path(req)` percent-decodes the path: `/caf%C3%A9` becomes `/café`.
`+` stays `+`, because only queries and forms use it for a space.

It returns `nothing` when decoding the whole path would be ambiguous or unsafe,
so you can answer 400:

| Path contains | Why it is refused |
|---|---|
| `%2F` (an encoded `/`) | after decoding, it could not be told apart from a separator |
| `%00` | a NUL byte truncates C strings and file names |
| a malformed escape (`%zz`, `%4`, a final `%`) | it has no meaning |
| bytes that are not valid UTF-8 (`%FF`) | the result would not be a valid `String` |

```@example urls
decoded_path(Request(; uri = "/caf%C3%A9/a+b")), decoded_path(Request(; uri = "/files/a%2Fb"))
```

The decoded path is not normalised: `/a/%2E%2E/b` decodes to `/a/../b`. Never
join it to a directory without checking; [`sendfile`](@ref) and
`public_folder` do their own checks.

If your URLs may carry an encoded `/` inside one segment (a file name, an
identifier), split the raw path first and decode each segment:

```@example urls
segments = percent_decode.(split(path(uri(Request(; uri = "/files/a%2Fb/v1"))), '/'; keepempty = false))
```

## Forms

A browser posting an HTML form, and `curl -d` or `--data-urlencode`, send an
`application/x-www-form-urlencoded` body. `parse_form(req)` parses `body(req)`
with the query rules above. Check the `content-type` first if the route also
accepts other bodies:

```@eval
Main.example("urls_form.jl")
```

```sh
$ curl http://127.0.0.1:8080/signup -d 'user=Ada+Lovelace&role=admin&role=dev%26ops'
welcome Ada Lovelace
roles: admin, dev&ops
```

`parse_form` also takes a `String` or bytes, for example a body you read with
[`body_stream`](@ref). `multipart/form-data` (file uploads from a form) is a
different format and is not parsed by Facil.

## Decoding rules

Decoding never throws on what a client sends. Following the WHATWG URL
standard, a `%` that is not followed by two hex digits is kept as it is, and
bytes that do not form valid UTF-8 become `'�'`:

```@example urls
percent_decode("100%"), percent_decode("a%zz"), percent_decode("%FF"), percent_decode("a+b"; plus = true)
```

`percent_encode` escapes every byte except `A-Z a-z 0-9 - . _ ~`. Use it to
build a query string, a `location` header or a cookie value:

```@example urls
"/search?q=" * percent_encode("café & co")
```

## Coming from other libraries

| Elsewhere | Facil |
|---|---|
| Node `url.searchParams.get(k)`, Express `req.query.k` | `query_param(req, k)` |
| Node `url.searchParams.getAll(k)` | `[v for (n, v) in query_params(req) if n == k]` |
| Node `[...url.searchParams]` | `query_params(req)` |
| Express `express.urlencoded()` then `req.body` | `parse_form(req)` |
| Node `decodeURIComponent(s)` / `encodeURIComponent(s)` | `percent_decode(s)` / `percent_encode(s)` |
| HTTP.jl `HTTP.queryparams(uri)` (a `Dict`) | `Dict(query_params(req))` |
| URIs.jl `queryparampairs(q)` | `parse_query(q)` |
| URIs.jl `unescapeuri(s)` / `escapeuri(s)` | `percent_decode(s)` / `percent_encode(s)` |
| Rust `url.query_pairs()`, `form_urlencoded::parse` | `query_params(req)`, `parse_form(body)` |

The names differ from URIs.jl's on purpose: `using Facil, URIs` in one module
works without either package's names hiding the other's.
