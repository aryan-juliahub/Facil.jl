export Response, ResponseParts, status

"""
    Response{T}

An HTTP response: `status`, `version`, `headers`, `extensions` and a `body` of type `T`.

    Response(; status=StatusCodes.OK, version=Versions.HTTP_11,
               headers=HeaderMap{HeaderValue}(), extensions=Extensions(), body=nothing)
    Response(status, body; version, headers, extensions)
    Response(s::StatusCode; ...)      # status `s`, body `nothing`
    Response(body)                    # status 200; the crate's `Response::new`
    Response(parts::ResponseParts, body)
    Response{T}(; ...)                # body defaults as for `Request{T}()`
    Response(s::StatusCode, v::Version, h::HeaderMap{HeaderValue}, e::Extensions, body)

`status` may be an integer or a string of three digits (`InvalidStatusCode` otherwise);
`headers` and `extensions` convert as for [`Request`](@ref). A single positional argument
is the body unless it is a `StatusCode`; a bare integer throws `ArgumentError`, so write
`Response(StatusCode(404))` or `Response(StatusCode(404), body)`.

Fields are read with `status(r)`, `version(r)`, `headers(r)`, `extensions(r)`, `body(r)`
or `r.status`, ... and replaced with `r.status = 404`, `r.body = ...` (converted to `T`).
`map(f, r)` gives a response with body `f(r.body)`.
"""
mutable struct Response{T}
    status::StatusCode
    version::Version
    headers::HeaderMap{HeaderValue}
    extensions::Extensions
    body::T
end

"""
    ResponseParts(; status, version, headers, extensions)
    parts(r::Response)

A response without its body (the crate's `response::Parts`). `parts(r)` shares `r`'s
headers and extensions; `Response(parts, body)` puts a body back.
"""
mutable struct ResponseParts
    status::StatusCode
    version::Version
    headers::HeaderMap{HeaderValue}
    extensions::Extensions
end

function Response(; status=StatusCodes.OK, version=Versions.HTTP_11,
                  headers=HeaderMap{HeaderValue}(), extensions=Extensions(), body=nothing)
    return Response(StatusCode(status), _r_version(version), _r_headers(headers),
        _r_extensions(extensions), body)
end

function Response{T}(; status=StatusCodes.OK, version=Versions.HTTP_11,
                     headers=HeaderMap{HeaderValue}(), extensions=Extensions(),
                     body=_r_default(T)) where {T}
    return Response{T}(StatusCode(status), _r_version(version), _r_headers(headers),
        _r_extensions(extensions), body)
end

Response(status, body; kw...) = Response(; status, body, kw...)
Response(body) = Response(; body)
Response(status::StatusCode; kw...) = Response(; status, kw...)
Response(::Integer; kw...) = throw(ArgumentError(
    "Response(::Integer) is ambiguous; write Response(StatusCode(404)) or Response(StatusCode(404), body)"))
Response(p::ResponseParts, body) = Response(p.status, p.version, p.headers, p.extensions, body)

ResponseParts(; status=StatusCodes.OK, version=Versions.HTTP_11,
              headers=HeaderMap{HeaderValue}(), extensions=Extensions()) =
    ResponseParts(StatusCode(status), _r_version(version), _r_headers(headers),
        _r_extensions(extensions))

parts(r::Response) = ResponseParts(r.status, r.version, r.headers, r.extensions)

Base.map(f, r::Response) = Response(r.status, r.version, r.headers, r.extensions, f(r.body))

Base.setproperty!(r::Response, f::Symbol, v) = _r_setfield!(r, f, v)
Base.setproperty!(p::ResponseParts, f::Symbol, v) = _r_setfield!(p, f, v)

"`status(r)` is the [`StatusCode`](@ref) of a `Response` or `ResponseParts`."
status(r::Union{Response,ResponseParts}) = r.status
version(r::Union{Response,ResponseParts}) = r.version
headers(r::Union{Response,ResponseParts}) = r.headers
extensions(r::Union{Response,ResponseParts}) = r.extensions
body(r::Response) = r.body

_r_show_head(io::IO, r::Union{Response,ResponseParts}) = _r_show_fields(io, r, (:status, :version, :headers))

function Base.show(io::IO, r::Response)
    print(io, typeof(r), "(")
    _r_show_head(io, r)
    print(io, ", body=")
    show(io, r.body)
    print(io, ")")
end
function Base.show(io::IO, p::ResponseParts)
    print(io, "ResponseParts(")
    _r_show_head(io, p)
    print(io, ")")
end
