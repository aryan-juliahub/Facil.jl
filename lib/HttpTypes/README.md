# HttpTypes.jl

Common HTTP types for Julia: methods, status codes, versions, header names and values,
a header multimap, URIs, extensions, requests and responses. It is a pure-Julia port of
the Rust [`http`](https://github.com/hyperium/http) crate, version 1.5.0, with the
crate's validation rules and its tests. No dependencies; Julia 1.10 or later, on
Linux, macOS and Windows.

## Install

HttpTypes is not registered yet. It lives in `lib/HttpTypes` of the
[Facil.jl](https://github.com/aryan-juliahub/Facil.jl) repository:

```julia
using Pkg
Pkg.develop(path = "lib/HttpTypes")   # from a Facil.jl checkout
```

Facil re-exports every HttpTypes name, so `using Facil` is enough when you use
the server.

## Documentation

The full reference, with every type, function, error and constant, is at
<https://aryan-juliahub.github.io/Facil.jl/dev/api/httptypes/>. Every docstring
has a runnable example (`?HeaderMap` in the REPL shows the same text).

## Example

```julia
using HttpTypes

req = Request(; method = "POST", uri = "https://example.com/users?page=2",
              headers = ["Content-Type" => "application/json", "Accept" => "*/*"],
              body = """{"name":"ada"}""")

method(req) == Methods.POST           # true
host(uri(req)), query(uri(req))       # ("example.com", "page=2")
headers(req)[header.CONTENT_TYPE]     # hv"application/json"

req.uri = "/users/7"                  # converted; throws InvalidUri if bad
append!(headers(req), "x-trace", "abc")
insert!(extensions(req), UInt32(42))  # typed side-channel data

res = Response(StatusCodes.CREATED, "ok"; headers = [header.LOCATION => "/users/7"])
status(res)                           # StatusCodes.CREATED
string(status(res))                   # "201 Created"
Response(StatusCodes.NOT_FOUND)       # status 404, body nothing
Response(404, "not found")            # an integer status works next to a body
lens = map(length, res)               # Response{Int} with body 2

tryparse(HttpMethod, "G T")           # nothing
# Request(; method = "G T")           # throws InvalidMethod
# Response(404)                       # throws ArgumentError: status or body?
```

Rules that hold across the package:

- Constructors validate and throw a subtype of `HttpError`; `tryparse(T, src)`
  returns `nothing` instead.
- Strings convert wherever a typed value is expected (`req.method = "PUT"`,
  `headers[name] = "value"`).
- `show` (the REPL and containers) prints Julia that reads back: `Methods.GET`,
  `StatusCodes.NOT_FOUND`, `hn"accept"`, `hv"text/plain"`, `uri"/a?b"`,
  `Port(8080)`. `print` and `string` give the plain HTTP text.
- Paths and queries are kept as received: nothing is percent-decoded or split.

## Rust to Julia

| `http` crate | HttpTypes.jl |
|---|---|
| `Method`, `Method::GET` | `HttpMethod`, `Methods.GET` |
| `StatusCode::NOT_FOUND`, `as_u16()` | `StatusCodes.NOT_FOUND`, `UInt16(s)` |
| `Version::HTTP_11` | `Versions.HTTP_11` |
| `header::CONTENT_TYPE` | `header.CONTENT_TYPE` |
| `HeaderName::from_static("x")`, `HeaderValue::from_static("v")` | `hn"x"`, `hv"v"` |
| `HeaderMap::insert` / `append` / `get_all` / `entry` | `insert!` / `append!` / `get_all` / `entry` |
| `Uri`, `"/p".parse::<Uri>()`, `uri::Parts` | `Uri`, `Uri("/p")` or `uri"/p"`, `UriParts` |
| `Scheme::HTTPS` | `Schemes.HTTPS` |
| `Extensions::insert` / `get::<T>()` | `insert!(ext, v)` / `get(ext, T)` |
| `Request::builder().method(m).uri(u).header(k, v).body(b)` | `Request(; method=m, uri=u, headers=[k => v], body=b)` |
| `Request::get(u)` | `Request(Methods.GET, u)` |
| `Response::new(b)`, `Response::builder().status(404)` | `Response(b)`, `Response(StatusCodes.NOT_FOUND)` or `Response(; status=404)` |
| `req.method()`, `req.headers_mut()`, `*req.body_mut() = b` | `method(req)`, `headers(req)`, `req.body = b` |
| `into_parts()`, `from_parts(p, b)` | `parts(r)`, `Request(p, b)` / `Response(p, b)` |
| `request::Parts`, `response::Parts` | `RequestParts`, `ResponseParts` |
| `map(f)` | `map(f, r)` |
| `Result<T, E>` | constructor that throws, plus `tryparse` |
| `http::Error`, `err.get_ref()` | `HttpTypes.Error`, `HttpTypes.get_ref(err)` |
| `Bytes` | `String` |

## License

Dual-licensed under [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option,
the same as the `http` crate. The design, documentation and tests are derived from the
`http` crate, Copyright (c) 2017 http-rs authors; the Julia port is
Copyright (c) 2026 Abhimanyu Aryan.
