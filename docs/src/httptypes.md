# HttpTypes

HttpTypes is a pure-Julia port of the Rust [`http`](https://github.com/hyperium/http)
crate, version 1.5.0: methods, status codes, versions, header names and values, a
header multimap, URIs, extensions, requests and responses. It keeps the crate's
validation rules and its tests. It has no dependencies and can be used without
Facil (`lib/HttpTypes` in the repository). Facil re-exports all of its names.

## Rust to Julia

| Rust `http` crate | HttpTypes.jl |
|---|---|
| `http::Method`, `Method::GET` | `HttpMethod`, `Methods.GET` |
| `StatusCode::OK`, `.as_u16()` | `StatusCodes.OK`, `UInt16(s)` |
| `Version::HTTP_11` | `Versions.HTTP_11` |
| `header::CONTENT_TYPE` | `header.CONTENT_TYPE` |
| `HeaderName::from_static("x-id")` | `hn"x-id"` |
| `HeaderValue::from_static("text/plain")` | `hv"text/plain"` |
| `"/p".parse::<Uri>()` | `Uri("/p")`, or `uri"/p"` for a literal checked at macro expansion |
| `HeaderMap::insert` (returns the old value) | `insert!(h, k, v)` (returns the old value or `nothing`) |
| `HeaderMap::append` (returns `bool`) | `append!(h, k, v)` (returns `Bool`) |
| `HeaderMap::get_all`, `entry` | `get_all`, `entry` |
| `map.insert(k, v);` used as a statement | `h[k] = v` |
| `Request::builder().method(m).uri(u).header(k, v).body(b)` | `Request(; method = m, uri = u, headers = [k => v], body = b)` |
| `Request::get(u)` | `Request(Methods.GET, u)` |
| `Response::builder().status(404).body(b)` | `Response(StatusCodes.NOT_FOUND, b)` or `Response(; status = 404, body = b)` |
| `req.method()`, `req.headers_mut()`, `*req.body_mut() = b` | `method(req)`, `headers(req)`, `req.body = b` |
| `into_parts()`, `from_parts(p, b)` | `parts(r)`, `Request(p, b)` / `Response(p, b)` |
| `request::Parts`, `response::Parts`, `uri::Parts` | `RequestParts`, `ResponseParts`, `UriParts` |
| `Scheme::HTTPS` | `Schemes.HTTPS` |
| `Extensions::insert`, `get::<T>()` | `insert!(ext, v)`, `get(ext, T)` |
| `map(f)` on a request or response | `map(f, r)` |
| `Result<T, E>` | a constructor that throws, plus `tryparse` that returns `nothing` |
| `http::Error`, `err.get_ref()` | `HttpTypes.Error`, `HttpTypes.get_ref(err)` |
| `Bytes` | `String` |

`Method` is spelled `HttpMethod` because `Method` is taken by `Base.Method`.
Constants live in submodules (`Methods`, `StatusCodes`, `Versions`, `Schemes`,
`header`). Every error is a subtype of `HttpError`.

`show` prints Julia that reads back (`Methods.GET`, `StatusCodes.NOT_FOUND`,
`hn"accept"`, `uri"/a?b"`); `print` and `string` give the HTTP text
(`string(StatusCodes.NOT_FOUND) == "404 Not Found"`).

## Example

```julia
using HttpTypes

m = Methods.GET
s = StatusCodes.OK
UInt16(StatusCodes.NOT_FOUND)
string(StatusCodes.NOT_FOUND)
Versions.HTTP_11

h = HeaderMap()
insert!(h, header.CONTENT_TYPE, "text/plain")
old = insert!(h, header.CONTENT_TYPE, "text/html")
append!(h, "x-trace", "a")
append!(h, "x-trace", "b")
collect(get_all(h, "x-trace"))
h[header.CONTENT_TYPE]

req = Request(; method = Methods.POST, uri = "https://example.com/users?page=2",
              headers = [header.CONTENT_TYPE => "application/json"], body = "{}")
host(uri(req)), path(uri(req)), query(uri(req))

p = parts(req)
req2 = Request(p, "new body")

tryparse(HttpMethod, "G T")
tryparse(Uri, "http://[::1")
e = try Request(; method = "G T") catch err; err end

name, value, target = hn"x-request-id", hv"text/plain", uri"/static?x=1"

err = HttpTypes.Error(e)
HttpTypes.get_ref(err) isa InvalidMethod
```

## HttpTypes API

```@docs
HttpTypes
```

### Methods, status codes, versions

```@docs
HttpMethod
Methods
is_safe
is_idempotent
StatusCode
StatusCodes
canonical_reason
is_informational
is_success
is_redirection
is_client_error
is_server_error
Version
Versions
```

### Headers

```@docs
header
HeaderName
@hn_str
from_static
from_lowercase
as_str
HeaderValue
@hv_str
to_str
is_sensitive
set_sensitive
HeaderMap
get_all
keys_len
remove!
remove_entry!
remove_entry_mult!
drain!
extend!
reserve!
insert_mult!
entry
OccupiedEntry
VacantEntry
key
or_insert!
or_insert_with!
insert_entry!
```

### URIs

```@docs
Uri
@uri_str
UriParts
Scheme
Schemes
scheme
scheme_str
Authority
authority
host
port
port_u16
Port
PathAndQuery
path_and_query
path
query
```

### Requests, responses, extensions

```@docs
Request
RequestParts
Response
ResponseParts
parts
method
uri
version
headers
extensions
body
status
Extensions
```

### Errors

```@docs
HttpError
HttpTypes.Error
HttpTypes.get_ref
InvalidMethod
InvalidStatusCode
InvalidHeaderName
InvalidHeaderValue
ToStrError
MaxSizeReached
InvalidUri
InvalidUriParts
```
