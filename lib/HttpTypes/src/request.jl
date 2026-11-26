export Request, RequestParts, parts, method, uri, version, headers, extensions, body

"""
    Request(; method = Methods.GET, uri = uri"/", version = Versions.HTTP_11,
              headers = HeaderMap(), extensions = Extensions(), body = nothing)
    Request(method, uri, body = nothing; version, headers, extensions)
    Request(body)
    Request(parts::RequestParts, body)
    Request{T}(; method, uri, version, headers, extensions, body)
    Request(method::HttpMethod, uri::Uri, version::Version, headers::HeaderMap{HeaderValue}, extensions::Extensions, body)

An HTTP request: a method, a target URI, a protocol version, headers, extensions
and a body of type `T`.

# Arguments
- `method`: an [`HttpMethod`](@ref), or a string or bytes to parse as one.
- `uri`: a [`Uri`](@ref), or a string or bytes to parse as one.
- `version`: a [`Version`](@ref).
- `headers`: a [`HeaderMap`](@ref) (used as is, not copied) or any iterable of
  `name => value` pairs, added in order with repeated names kept.
- `extensions`: an [`Extensions`](@ref) (used as is) or a tuple of values to
  insert.
- `body`: any value; its type is the request's type parameter `T`. With
  `Request{T}(; ...)` and no `body`, the body is `""` for `String`, `nothing`
  for `Nothing`, `zero(T)` for numbers and `T()` otherwise.

`Request(body)` takes every default (the crate's `Request::new`). The last,
all-positional form takes values of exactly the field types, converts nothing,
and is the cheapest.

# Throws
- [`InvalidMethod`](@ref), [`InvalidUri`](@ref), [`InvalidHeaderName`](@ref),
  [`InvalidHeaderValue`](@ref), [`MaxSizeReached`](@ref) when an argument does
  not convert.
- `MethodError` for a `version` that is not a `Version`.

# Reading and changing
- Read with the accessors [`method`](@ref), [`uri`](@ref), [`version`](@ref),
  [`headers`](@ref), [`extensions`](@ref), [`body`](@ref), or the fields of the
  same names (`r.method`).
- Assign a field to replace it: `r.method = "PUT"`, `r.uri = "/new"`,
  `r.body = ...`. The value is converted like the constructor argument (the
  body to `T`), and throws the same errors.
- Change headers and extensions in place: `headers(r)["accept"] = "*/*"`.
- `map(f, r)` returns a request with body `f(body(r))`; it shares the headers
  and extensions of `r`.
- [`parts`](@ref)`(r)` is the request without its body.

`show` prints the method, URI, version, headers and body, but not the
extensions.

# Examples
```jldoctest
julia> req = Request(; method = "POST", uri = "/users?page=2",
                     headers = ["Content-Type" => "application/json"], body = "{}")
Request{String}(method=Methods.POST, uri=uri"/users?page=2", version=Versions.HTTP_11, headers=HeaderMap(hn"content-type" => hv"application/json"), body="{}")

julia> method(req), path(uri(req)), body(req)
(Methods.POST, "/users", "{}")

julia> headers(req)[header.CONTENT_TYPE]
hv"application/json"

julia> req.method = "PUT"; append!(headers(req), "x-trace", "abc");

julia> method(req), length(headers(req))
(Methods.PUT, 2)

julia> body(map(length, req))
2

julia> Request(Methods.GET, "/health")
Request{Nothing}(method=Methods.GET, uri=uri"/health", version=Versions.HTTP_11, headers=HeaderMap(), body=nothing)
```
"""
mutable struct Request{T}
    method::HttpMethod
    uri::Uri
    version::Version
    headers::HeaderMap{HeaderValue}
    extensions::Extensions
    body::T
end

"""
    RequestParts(; method = Methods.GET, uri = uri"/", version = Versions.HTTP_11,
                   headers = HeaderMap(), extensions = Extensions())

The head of a request, without a body (the crate's `request::Parts`).

It has the fields `method`, `uri`, `version`, `headers` and `extensions`, with
the same conversions, accessors and assignment rules as [`Request`](@ref).
[`parts`](@ref)`(req)` takes the head off a request and `Request(parts, body)`
puts a body on one; use the pair to swap a request's body for one of another
type while keeping everything else.

# Examples
```jldoctest
julia> req = Request(; method = "POST", uri = "/upload", body = "raw text");

julia> p = parts(req)
RequestParts(method=Methods.POST, uri=uri"/upload", version=Versions.HTTP_11, headers=HeaderMap())

julia> body(Request(p, codeunits(body(req)))) isa AbstractVector{UInt8}
true
```
"""
mutable struct RequestParts
    method::HttpMethod
    uri::Uri
    version::Version
    headers::HeaderMap{HeaderValue}
    extensions::Extensions
end

_r_headers(h::HeaderMap{HeaderValue}) = h
_r_headers(itr) = HeaderMap{HeaderValue}(itr)
_r_extensions(e::Extensions) = e
function _r_extensions(vals::Tuple)
    e = Extensions()
    foreach(v -> insert!(e, v), vals)
    return e
end
_r_version(v::Version) = v

_r_default(::Type{T}) where {T} = T()
_r_default(::Type{Nothing}) = nothing
_r_default(::Type{String}) = ""
_r_default(::Type{T}) where {T<:Number} = zero(T)

function Request(; method=Methods.GET, uri=_U_DEFAULT, version=Versions.HTTP_11,
                 headers=HeaderMap{HeaderValue}(), extensions=Extensions(), body=nothing)
    return Request(HttpMethod(method), Uri(uri), _r_version(version), _r_headers(headers),
        _r_extensions(extensions), body)
end

function Request{T}(; method=Methods.GET, uri=_U_DEFAULT, version=Versions.HTTP_11,
                    headers=HeaderMap{HeaderValue}(), extensions=Extensions(),
                    body=_r_default(T)) where {T}
    return Request{T}(HttpMethod(method), Uri(uri), _r_version(version), _r_headers(headers),
        _r_extensions(extensions), body)
end

Request(method, uri, body=nothing; kw...) = Request(; method, uri, body, kw...)
Request(body) = Request(; body)
Request(p::RequestParts, body) = Request(p.method, p.uri, p.version, p.headers, p.extensions, body)

RequestParts(; method=Methods.GET, uri=_U_DEFAULT, version=Versions.HTTP_11,
             headers=HeaderMap{HeaderValue}(), extensions=Extensions()) =
    RequestParts(HttpMethod(method), Uri(uri), _r_version(version), _r_headers(headers),
        _r_extensions(extensions))

"""
    parts(r::Request) -> RequestParts
    parts(r::Response) -> ResponseParts

The head of a request or response, without its body.

The result shares its headers and extensions with `r`: changing them through
either changes both. The other fields are copies, so assigning
`parts(r).method = ...` does not change `r`. `Request(parts, body)` and
`Response(parts, body)` build a message from a head and a body.

# Examples
```jldoctest
julia> res = Response(StatusCodes.OK, "hello"; headers = ["content-type" => "text/plain"]);

julia> p = parts(res)
ResponseParts(status=StatusCodes.OK, version=Versions.HTTP_11, headers=HeaderMap(hn"content-type" => hv"text/plain"))

julia> headers(p) === headers(res)
true

julia> body(Response(p, 5))
5
```
"""
function parts end
parts(r::Request) = RequestParts(r.method, r.uri, r.version, r.headers, r.extensions)

Base.map(f, r::Request) = Request(r.method, r.uri, r.version, r.headers, r.extensions, f(r.body))

@inline function _r_setfield!(x, f::Symbol, v)
    f === :headers && return setfield!(x, f, _r_headers(v))
    f === :extensions && return setfield!(x, f, _r_extensions(v))
    return setfield!(x, f, convert(fieldtype(typeof(x), f), v))
end
Base.setproperty!(r::Request, f::Symbol, v) = _r_setfield!(r, f, v)
Base.setproperty!(p::RequestParts, f::Symbol, v) = _r_setfield!(p, f, v)

"""
    method(r::Union{Request,RequestParts}) -> HttpMethod

The request method. Compare it with a constant (`method(req) == Methods.POST`)
or with a string (`method(req) == "POST"`). Same as `r.method`.

# Examples
```jldoctest
julia> method(Request(; method = "DELETE", uri = "/users/1"))
Methods.DELETE
```
"""
method(r::Union{Request,RequestParts}) = r.method
"""
    uri(r::Union{Request,RequestParts}) -> Uri

The request target as a [`Uri`](@ref). Same as `r.uri`. Read it further with
[`path`](@ref), [`query`](@ref), [`host`](@ref) and the other `Uri` accessors.

# Examples
```jldoctest
julia> req = Request(Methods.GET, "/users/42?full=1");

julia> uri(req)
uri"/users/42?full=1"

julia> path(uri(req)), query(uri(req))
("/users/42", "full=1")
```
"""
uri(r::Union{Request,RequestParts}) = r.uri
"""
    version(r) -> Version

The protocol [`Version`](@ref) of a [`Request`](@ref), [`Response`](@ref),
[`RequestParts`](@ref) or [`ResponseParts`](@ref). Same as `r.version`.

# Examples
```jldoctest
julia> version(Request())
Versions.HTTP_11
```
"""
function version end
"""
    headers(r) -> HeaderMap{HeaderValue}

The [`HeaderMap`](@ref) of a [`Request`](@ref), [`Response`](@ref),
[`RequestParts`](@ref) or [`ResponseParts`](@ref). Same as `r.headers`.

The map itself is returned, not a copy: change it in place to change the
message's headers.

# Examples
```jldoctest
julia> res = Response(StatusCodes.OK, "hi");

julia> headers(res)[header.CONTENT_TYPE] = "text/plain";

julia> get(headers(res), "content-type", nothing)
hv"text/plain"
```
"""
function headers end
"""
    extensions(r) -> Extensions

The [`Extensions`](@ref) of a [`Request`](@ref), [`Response`](@ref),
[`RequestParts`](@ref) or [`ResponseParts`](@ref). Same as `r.extensions`.

The map itself is returned, not a copy: insert into it to attach data to the
message.

# Examples
```jldoctest
julia> req = Request();

julia> insert!(extensions(req), "user-7");

julia> get(extensions(req), String)
"user-7"
```
"""
function extensions end
"""
    body(r::Union{Request,Response})

The body of a [`Request`](@ref) or [`Response`](@ref): a value of the message's
type parameter (`String` for a `Request{String}`). Same as `r.body`. It covers
both the crate's `body()` and `into_body()`.

# Examples
```jldoctest
julia> body(Request(; body = "payload"))
"payload"

julia> body(Response(StatusCodes.NO_CONTENT)) === nothing
true
```
"""
function body end

version(r::Union{Request,RequestParts}) = r.version
headers(r::Union{Request,RequestParts}) = r.headers
extensions(r::Union{Request,RequestParts}) = r.extensions
body(r::Request) = r.body

_r_show_head(io::IO, r) = _r_show_fields(io, r, (:method, :uri, :version, :headers))

function _r_show_fields(io::IO, r, fields)
    for (i, f) in enumerate(fields)
        print(io, i == 1 ? "" : ", ", f, '=')
        show(io, getfield(r, f))
    end
end

function Base.show(io::IO, r::Request)
    print(io, typeof(r), "(")
    _r_show_head(io, r)
    print(io, ", body=")
    show(io, r.body)
    print(io, ")")
end
function Base.show(io::IO, p::RequestParts)
    print(io, "RequestParts(")
    _r_show_head(io, p)
    print(io, ")")
end
