```@meta
CurrentModule = HttpTypes
```

# URIs

This page documents [`Uri`](@ref), the type of a request's target, its
accessors, and the component types [`Scheme`](@ref), [`Authority`](@ref),
[`PathAndQuery`](@ref) and [`Port`](@ref). Use it to read the path and query of
a request, or to parse and build URLs.

## Reading a request target

`uri(req)` returns a `Uri`. A server normally sees the origin form, a path with
an optional query:

```@repl uri
using HttpTypes
req = Request(Methods.GET, "/users/42?full=1&sort=name");
u = uri(req)
path(u)
query(u)
```

There is no host in such a target, so the authority accessors return `nothing`.
The host the client asked for is in the `host` header:

```@repl uri
host(u), port(u), scheme(u)
```

`query` returns `nothing` when the target has no `?`, and an empty string when
it ends with one:

```@repl uri
query(uri"/users"), query(uri"/users?")
```

!!! warning "Nothing is decoded"
    `path` and `query` return the text exactly as the client sent it. `%20`
    stays `%20`, `+` stays `+`, the query is not split into parameters, and
    `..` segments are not resolved. Decode before you compare a path with a
    file name or use a query value.

```@repl uri
path(uri"/files/my%20report.pdf")
```

## Parsing and building URLs

`Uri` also parses absolute URLs:

```@repl uri
u = Uri("https://user@example.com:8443/a/b?x=1")
scheme(u), scheme_str(u)
authority(u)
host(u), port(u), port_u16(u)
path_and_query(u)
```

No default port is filled in:

```@repl uri
port(uri"https://example.com/") === nothing
```

Build a URI from components with keywords, or take one apart with
[`UriParts`](@ref), change a component and put it back together:

```@repl uri
Uri(; scheme = "https", authority = "example.com", path_and_query = "/search?q=julia")
p = UriParts(uri"http://example.com/a");
p.scheme = Schemes.HTTPS;
Uri(p)
```

Comparison ignores the case of the scheme and host, but not of the path:

```@repl uri
uri"HTTP://EXAMPLE.com/a" == uri"http://example.com/a"
uri"http://example.com/a" == uri"http://example.com/A"
```

## Reference: Uri

```@docs
Uri
@uri_str
UriParts
path
query
path_and_query
scheme
scheme_str
authority
host
port
port_u16
HttpTypes.uri_from_target
```

## Reference: components

```@docs
Scheme
Schemes
Authority
PathAndQuery
Port
```

See also [`InvalidUri`](@ref) and [`InvalidUriParts`](@ref) on the
[errors page](errors.md).
