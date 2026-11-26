```@meta
CurrentModule = HttpTypes
```

# HttpTypes

This is the reference for HttpTypes, the package that defines the values a Facil
handler receives and returns: [`Request`](@ref), [`Response`](@ref), methods,
status codes, headers and URIs. Use these pages to look up what a type accepts,
what a function returns and what it throws.

HttpTypes is a pure-Julia port of the Rust [`http`](https://github.com/hyperium/http)
crate, version 1.5.0, with the crate's validation rules and its tests. It only
describes HTTP messages; it does no I/O. It has no dependencies and runs on
Linux, macOS and Windows.

Facil re-exports every name HttpTypes exports, so `using Facil` is enough. To
use the types without a server, load the package on its own (it lives in
`lib/HttpTypes` of the Facil repository):

```julia
using HttpTypes
```

## The pages

| Page | What it covers |
|:--|:--|
| [Requests and responses](messages.md) | [`Request`](@ref), [`Response`](@ref), their parts and accessors |
| [Methods](methods.md) | [`HttpMethod`](@ref), `Methods.GET` and friends |
| [Status codes](status.md) | [`StatusCode`](@ref), every `StatusCodes` constant |
| [Versions](versions.md) | [`Version`](@ref), `Versions.HTTP_11` |
| [Headers](headers.md) | [`HeaderName`](@ref), [`HeaderValue`](@ref), [`HeaderMap`](@ref), every `header` constant |
| [URIs](uri.md) | [`Uri`](@ref) and its components |
| [Extensions](extensions.md) | [`Extensions`](@ref), typed data attached to a message |
| [Errors](errors.md) | [`HttpError`](@ref) and its subtypes |

## A first look

```@repl index
using HttpTypes
req = Request(; method = "POST", uri = "/users?page=2",
              headers = ["Content-Type" => "application/json"], body = "{\"name\":\"ada\"}")
method(req) == Methods.POST
path(uri(req)), query(uri(req))
headers(req)[header.CONTENT_TYPE]
res = Response(StatusCodes.CREATED, "ok"; headers = [header.LOCATION => "/users/7"])
status(res), string(status(res))
```

## Conventions

These rules hold across the package.

**Constructors validate and throw; `tryparse` returns `nothing`.** Every type
that can be built from text has both forms. The errors are all subtypes of
[`HttpError`](@ref).

```@repl index
tryparse(HttpMethod, "G T")
tryparse(Uri, "/has space")
try
    HeaderName("bad name")
catch e
    e
end
```

**Strings convert where a typed value is expected.** Constructors, field
assignment and [`HeaderMap`](@ref) functions take a `String` (or bytes) and
parse it, so you rarely build the small types by hand.

```@repl index
req.method = "PUT";
req.uri = "/users/7";
req
```

**Constants live in namespaces.** `Methods.GET`, `StatusCodes.NOT_FOUND`,
`Versions.HTTP_11`, `Schemes.HTTPS`, `header.CONTENT_TYPE`. The namespaces are
exported; the constants inside them are not.

**`show` prints Julia, `print` prints HTTP.** What the REPL displays can be
pasted back as code; `string` and `print` give the text that goes on the wire.

```@repl index
StatusCodes.NOT_FOUND, string(StatusCodes.NOT_FOUND)
header.CONTENT_TYPE, string(header.CONTENT_TYPE)
uri"/a?b", string(uri"/a?b")
```

**Literals are checked when the code is parsed.** [`hn"..."`](@ref @hn_str),
[`hv"..."`](@ref @hv_str) and [`uri"..."`](@ref @uri_str) build a
[`HeaderName`](@ref), [`HeaderValue`](@ref) and [`Uri`](@ref) at macro
expansion, so a typo fails before the program runs and the value costs nothing
at run time.

**Nothing is decoded.** Paths and queries are kept as received: no
percent-decoding, no splitting of query parameters, no path normalisation.

## Text forms

`as_str` gives the wire text of any of the small types without allocating.

```@docs
as_str
```

## Coming from the Rust `http` crate

| Rust `http` crate | HttpTypes |
|:--|:--|
| `http::Method`, `Method::GET` | [`HttpMethod`](@ref), `Methods.GET` |
| `StatusCode::NOT_FOUND`, `.as_u16()` | `StatusCodes.NOT_FOUND`, `UInt16(s)` |
| `Version::HTTP_11` | `Versions.HTTP_11` |
| `header::CONTENT_TYPE` | `header.CONTENT_TYPE` |
| `HeaderName::from_static("x-id")` | `hn"x-id"` |
| `HeaderValue::from_static("text/plain")` | `hv"text/plain"` |
| `"/p".parse::<Uri>()` | `Uri("/p")`, or `uri"/p"` for a literal |
| `uri::Parts`, `Scheme::HTTPS` | [`UriParts`](@ref), `Schemes.HTTPS` |
| `HeaderMap::insert` (returns the old value) | `insert!(h, k, v)` (returns the old value or `nothing`) |
| `map.insert(k, v);` as a statement | `h[k] = v` |
| `HeaderMap::append` (returns `bool`) | `append!(h, k, v)` (returns `Bool`) |
| `HeaderMap::get_all`, `entry` | [`get_all`](@ref), [`entry`](@ref) |
| `Request::builder().method(m).uri(u).header(k, v).body(b)` | `Request(; method = m, uri = u, headers = [k => v], body = b)` |
| `Request::get(u)` | `Request(Methods.GET, u)` |
| `Response::new(b)` | `Response(b)` |
| `Response::builder().status(404).body(b)` | `Response(StatusCodes.NOT_FOUND, b)` or `Response(; status = 404, body = b)` |
| `req.method()`, `req.headers_mut()`, `*req.body_mut() = b` | `method(req)`, `headers(req)`, `req.body = b` |
| `into_parts()`, `from_parts(p, b)` | [`parts`](@ref)`(r)`, `Request(p, b)` / `Response(p, b)` |
| `request::Parts`, `response::Parts` | [`RequestParts`](@ref), [`ResponseParts`](@ref) |
| `map(f)` on a request or response | `map(f, r)` |
| `Extensions::insert`, `get::<T>()` | `insert!(ext, v)`, `get(ext, T)` |
| `Result<T, E>` | a constructor that throws, plus `tryparse` that returns `nothing` |
| `http::Error`, `err.get_ref()` | [`HttpTypes.Error`](@ref), [`HttpTypes.get_ref`](@ref)`(err)` |
| `Bytes` | `String` |

`Method` is spelled `HttpMethod` because `Method` is taken by `Base.Method`.

## All names

```@docs
HttpTypes
```

**Messages:** [`Request`](@ref), [`RequestParts`](@ref), [`Response`](@ref),
[`ResponseParts`](@ref), [`parts`](@ref), [`method`](@ref), [`uri`](@ref),
[`status`](@ref), [`version`](@ref), [`headers`](@ref), [`extensions`](@ref),
[`body`](@ref)

**Methods:** [`HttpMethod`](@ref), [`Methods`](@ref), [`is_safe`](@ref),
[`is_idempotent`](@ref)

**Status codes:** [`StatusCode`](@ref), [`StatusCodes`](@ref),
[`canonical_reason`](@ref), [`is_informational`](@ref), [`is_success`](@ref),
[`is_redirection`](@ref), [`is_client_error`](@ref), [`is_server_error`](@ref)

**Versions:** [`Version`](@ref), [`Versions`](@ref)

**Header names:** [`HeaderName`](@ref), [`header`](@ref),
[`@hn_str`](@ref), [`from_static`](@ref), [`from_lowercase`](@ref)

**Header values:** [`HeaderValue`](@ref), [`@hv_str`](@ref), [`to_str`](@ref),
[`is_sensitive`](@ref), [`set_sensitive`](@ref)

**Header map:** [`HeaderMap`](@ref), [`get_all`](@ref), [`keys_len`](@ref),
[`remove!`](@ref), [`drain!`](@ref), [`extend!`](@ref), [`reserve!`](@ref),
[`entry`](@ref), [`OccupiedEntry`](@ref), [`VacantEntry`](@ref), [`key`](@ref),
[`or_insert!`](@ref), [`or_insert_with!`](@ref), [`insert_entry!`](@ref),
[`insert_mult!`](@ref), [`remove_entry!`](@ref), [`remove_entry_mult!`](@ref)

**URIs:** [`Uri`](@ref), [`@uri_str`](@ref), [`UriParts`](@ref),
[`scheme`](@ref), [`scheme_str`](@ref), [`authority`](@ref), [`host`](@ref),
[`port`](@ref), [`port_u16`](@ref), [`path_and_query`](@ref), [`path`](@ref),
[`query`](@ref), [`Scheme`](@ref), [`Schemes`](@ref), [`Authority`](@ref),
[`PathAndQuery`](@ref), [`Port`](@ref)

**Extensions:** [`Extensions`](@ref)

**Errors:** [`HttpError`](@ref), [`InvalidMethod`](@ref),
[`InvalidStatusCode`](@ref), [`InvalidHeaderName`](@ref),
[`InvalidHeaderValue`](@ref), [`ToStrError`](@ref), [`MaxSizeReached`](@ref),
[`InvalidUri`](@ref), [`InvalidUriParts`](@ref)

**Text:** [`as_str`](@ref)

**Public but not exported:** [`HttpTypes.Error`](@ref),
[`HttpTypes.get_ref`](@ref), [`HttpTypes.unchecked`](@ref),
[`HttpTypes.uri_from_target`](@ref), [`HttpTypes.standard_header`](@ref),
[`HttpTypes.standard_index`](@ref), [`HttpTypes.STANDARD_HEADER_TABLE`](@ref)
