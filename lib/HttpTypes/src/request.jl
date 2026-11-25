export Request, RequestParts, parts, method, uri, version, headers, extensions, body

"""
    Request{T}

An HTTP request: `method`, `uri`, `version`, `headers`, `extensions` and a `body` of type `T`.

    Request(; method=Methods.GET, uri=Uri(), version=Versions.HTTP_11,
              headers=HeaderMap{HeaderValue}(), extensions=Extensions(), body=nothing)
    Request(method, uri, body=nothing; version, headers, extensions)
    Request(body)                     # all defaults; the crate's `Request::new`
    Request(parts::RequestParts, body)
    Request{T}(; ...)                 # body defaults to `T()`, `""`, `zero(T)` or `nothing`
    Request(m::HttpMethod, u::Uri, v::Version, h::HeaderMap{HeaderValue}, e::Extensions, body)

`method` and `uri` may be strings or bytes and `headers` any iterable of `name => value`
pairs; they are converted on construction and assignment, throwing `InvalidMethod`,
`InvalidUri`, `InvalidUriParts`, `InvalidHeaderName` or `InvalidHeaderValue`.
`extensions` may also be a tuple of values to insert. A `HeaderMap` or `Extensions`
passed in is used as is, not copied. The last form converts nothing and is the cheapest.

Fields are read with `method(r)`, `uri(r)`, ..., `body(r)` or `r.method`, ... and
replaced with `r.method = "PUT"`, `r.body = ...` (converted to `T`); headers and
extensions are changed in place. `map(f, r)` gives a request with body `f(r.body)`.
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
    RequestParts(; method, uri, version, headers, extensions)
    parts(r::Request)

A request without its body (the crate's `request::Parts`). `parts(r)` shares `r`'s
headers and extensions; `Request(parts, body)` puts a body back.
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

The head of a request or response without its body; it shares headers and extensions.
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

"`method(r)` is the [`HttpMethod`](@ref) of a `Request` or `RequestParts`."
method(r::Union{Request,RequestParts}) = r.method
"`uri(r)` is the [`Uri`](@ref) of a `Request` or `RequestParts`."
uri(r::Union{Request,RequestParts}) = r.uri
"`version(r)` is the protocol [`Version`](@ref) of a `Request`, `Response` or their parts."
function version end
"`headers(r)` is the `HeaderMap` of a `Request`, `Response` or their parts; change it in place."
function headers end
"`extensions(r)` is the [`Extensions`](@ref) of a `Request`, `Response` or their parts; change it in place."
function extensions end
"`body(r)` is the body of a `Request` or `Response` (the crate's `body` and `into_body`)."
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
