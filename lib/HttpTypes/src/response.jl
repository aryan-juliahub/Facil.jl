export Response, ResponseParts, status

"""
    Response(; status = StatusCodes.OK, version = Versions.HTTP_11,
               headers = HeaderMap(), extensions = Extensions(), body = nothing)
    Response(status, body; version, headers, extensions)
    Response(status::StatusCode; version, headers, extensions)
    Response(body)
    Response(parts::ResponseParts, body)
    Response{T}(; status, version, headers, extensions, body)
    Response(status::StatusCode, version::Version, headers::HeaderMap{HeaderValue}, extensions::Extensions, body)

An HTTP response: a status code, a protocol version, headers, extensions and a
body of type `T`.

# Arguments
- `status`: a [`StatusCode`](@ref), an integer in `100:999`, or a string of
  three digits.
- `version`: a [`Version`](@ref).
- `headers`: a [`HeaderMap`](@ref) (used as is, not copied) or any iterable of
  `name => value` pairs.
- `extensions`: an [`Extensions`](@ref) (used as is) or a tuple of values to
  insert.
- `body`: any value; its type is the response's type parameter `T`. Defaults as
  for [`Request`](@ref).

# One positional argument
- `Response(s::StatusCode)` has status `s` and body `nothing`.
- `Response(body)` has status 200 and that body (the crate's `Response::new`).
- `Response(404)` throws an `ArgumentError`, because a bare integer could mean
  either. Write `Response(StatusCodes.NOT_FOUND)` or `Response(StatusCode(404))`
  for an empty 404, and `Response(404, "not found")` for one with a body: with
  two positional arguments an integer status is accepted.

The last, all-positional form converts nothing and is the cheapest.

# Throws
- [`InvalidStatusCode`](@ref), [`InvalidHeaderName`](@ref),
  [`InvalidHeaderValue`](@ref), [`MaxSizeReached`](@ref) when an argument does
  not convert.
- `ArgumentError` for `Response(::Integer)`.

# Reading and changing
- Read with [`status`](@ref), [`version`](@ref), [`headers`](@ref),
  [`extensions`](@ref), [`body`](@ref), or the fields of the same names.
- Assign a field to replace it: `r.status = 404`, `r.body = ...` (converted to
  `T`). Change headers and extensions in place.
- `map(f, r)` returns a response with body `f(body(r))`, sharing the headers
  and extensions of `r`.
- [`parts`](@ref)`(r)` is the response without its body.

`show` prints the status, version, headers and body, but not the extensions.

# Examples
```jldoctest
julia> res = Response(StatusCodes.CREATED, "ok"; headers = [header.LOCATION => "/users/7"])
Response{String}(status=StatusCodes.CREATED, version=Versions.HTTP_11, headers=HeaderMap(hn"location" => hv"/users/7"), body="ok")

julia> status(res), string(status(res)), body(res)
(StatusCodes.CREATED, "201 Created", "ok")

julia> Response(StatusCodes.NOT_FOUND)
Response{Nothing}(status=StatusCodes.NOT_FOUND, version=Versions.HTTP_11, headers=HeaderMap(), body=nothing)

julia> status(Response(404, "not found"))
StatusCodes.NOT_FOUND

julia> Response(404)
ERROR: ArgumentError: Response(::Integer) is ambiguous; write Response(StatusCode(404)) or Response(StatusCode(404), body)
[...]

julia> res.status = 200; status(res)
StatusCodes.OK
```
"""
mutable struct Response{T}
    status::StatusCode
    version::Version
    headers::HeaderMap{HeaderValue}
    extensions::Extensions
    body::T
end

"""
    ResponseParts(; status = StatusCodes.OK, version = Versions.HTTP_11,
                    headers = HeaderMap(), extensions = Extensions())

The head of a response, without a body (the crate's `response::Parts`).

It has the fields `status`, `version`, `headers` and `extensions`, with the same
conversions, accessors and assignment rules as [`Response`](@ref).
[`parts`](@ref)`(res)` takes the head off a response and `Response(parts, body)`
puts a body on one.

# Examples
```jldoctest
julia> p = ResponseParts(; status = 302, headers = [header.LOCATION => "/login"])
ResponseParts(status=StatusCodes.FOUND, version=Versions.HTTP_11, headers=HeaderMap(hn"location" => hv"/login"))

julia> Response(p, "")
Response{String}(status=StatusCodes.FOUND, version=Versions.HTTP_11, headers=HeaderMap(hn"location" => hv"/login"), body="")
```
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

"""
    status(r::Union{Response,ResponseParts}) -> StatusCode

The [`StatusCode`](@ref) of a response. Same as `r.status`. Compare it with a
constant or an integer (`status(res) == 200`), or classify it with
[`is_success`](@ref) and its siblings.

# Examples
```jldoctest
julia> res = Response(StatusCodes.NOT_FOUND);

julia> status(res), status(res) == 404, is_client_error(status(res))
(StatusCodes.NOT_FOUND, true, true)
```
"""
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
