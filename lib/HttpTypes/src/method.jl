export HttpMethod, Methods, InvalidMethod, is_safe, is_idempotent, as_str

"""
    InvalidMethod <: HttpError

Thrown by [`HttpMethod`](@ref) (and by anything that converts to one, such as
`Request(; method = ...)`) when the source is empty or holds a byte that is not
an RFC 9110 token character. The message is `invalid HTTP method`.

# Examples
```jldoctest
julia> HttpMethod("G T")
ERROR: invalid HTTP method
[...]

julia> tryparse(HttpMethod, "G T") === nothing
true
```
"""
struct InvalidMethod <: HttpError end
Base.showerror(io::IO, ::InvalidMethod) = print(io, "invalid HTTP method")

"""
    HttpMethod(src)
    HttpMethod(ptr::Ptr{UInt8}, len::Integer)
    HttpMethod()
    tryparse(HttpMethod, src)
    tryparse(HttpMethod, ptr, len)
    parse(HttpMethod, src)

A request method: `GET`, `POST`, or any other RFC 9110 token.

The ten standard methods are constants in `Methods` (`Methods.GET`, ...), and
parsing one of their names returns that constant. Any other valid token becomes
an extension method that keeps its text.

# Arguments
- `src`: an `AbstractString` or `AbstractVector{UInt8}` holding the method name, or
  an `HttpMethod` (returned as is).
- `ptr`, `len`: a pointer to `len` bytes holding the name; the bytes are copied
  only for an extension method.

# Returns
An `HttpMethod`. `HttpMethod()` is `Methods.GET`. The `tryparse` forms return
`nothing` instead of throwing.

# Throws
- [`InvalidMethod`](@ref) if `src` is empty or contains a byte outside the token
  characters (letters, digits and the punctuation RFC 9110 allows in a token;
  no spaces, control bytes or non-ASCII bytes).

# Notes
- Methods are case-sensitive: `HttpMethod("get")` is an extension method, not
  `Methods.GET`.
- `m == "GET"` compares with a string. Two extension methods are equal when
  their text is equal. Methods order (`isless`) and hash by their text.
- `string(m)`, `String(m)`, `print` and [`as_str`](@ref) give the token; `show`
  prints `Methods.GET` or `HttpMethod("PURGE")`.
- `convert(HttpMethod, src)` accepts strings and bytes, so a field or argument
  typed `HttpMethod` can be assigned a string.

# Examples
```jldoctest
julia> HttpMethod("POST")
Methods.POST

julia> HttpMethod("POST") === Methods.POST
true

julia> m = HttpMethod("PURGE")
HttpMethod("PURGE")

julia> m == "PURGE", string(m)
(true, "PURGE")

julia> HttpMethod("get") == Methods.GET
false

julia> tryparse(HttpMethod, "not a method") === nothing
true
```

See also [`is_safe`](@ref), [`is_idempotent`](@ref).
"""
struct HttpMethod
    tag::UInt8
    name::String
    global _m_unchecked(tag::UInt8, name::String) = new(tag, name)
end

const _M_NAMES = ("OPTIONS", "GET", "POST", "PUT", "DELETE", "HEAD", "TRACE", "CONNECT", "PATCH", "QUERY")
const _M_EXTENSION = 0x00

"""
    Methods

The standard request methods as [`HttpMethod`](@ref HttpTypes.HttpMethod) constants:

`Methods.OPTIONS`, `Methods.GET`, `Methods.POST`, `Methods.PUT`,
`Methods.DELETE`, `Methods.HEAD`, `Methods.TRACE`, `Methods.CONNECT`,
`Methods.PATCH`, `Methods.QUERY`.

The constants are not exported one by one; write `Methods.GET`.

# Examples
```jldoctest
julia> Methods.DELETE
Methods.DELETE

julia> Methods.GET == "GET"
true
```
"""
baremodule Methods end
for (i, n) in enumerate(_M_NAMES)
    Core.eval(Methods, :(const $(Symbol(n)) = $(_m_unchecked(UInt8(i), n))))
end

@inline _m_word(p::Ptr{UInt8}, ::Val{N}) where {N} = unsafe_load(Ptr{NTuple{N,UInt8}}(p))
@inline _m_is(p::Ptr{UInt8}, s::NTuple{N,UInt8}) where {N} = _m_word(p, Val(N)) === s

const _M_BYTES = map(n -> Tuple(codeunits(n)), _M_NAMES)

@inline function _tryparse_method(p::Ptr{UInt8}, n::Int)::Union{HttpMethod,Nothing}
    if n == 3
        _m_is(p, _M_BYTES[2]) && return Methods.GET
        _m_is(p, _M_BYTES[4]) && return Methods.PUT
    elseif n == 4
        _m_is(p, _M_BYTES[3]) && return Methods.POST
        _m_is(p, _M_BYTES[6]) && return Methods.HEAD
    elseif n == 5
        _m_is(p, _M_BYTES[9]) && return Methods.PATCH
        _m_is(p, _M_BYTES[7]) && return Methods.TRACE
        _m_is(p, _M_BYTES[10]) && return Methods.QUERY
    elseif n == 6
        _m_is(p, _M_BYTES[5]) && return Methods.DELETE
    elseif n == 7
        _m_is(p, _M_BYTES[1]) && return Methods.OPTIONS
        _m_is(p, _M_BYTES[8]) && return Methods.CONNECT
    elseif n <= 0
        return nothing
    end
    return _m_extension(p, n)
end

function _m_extension(p::Ptr{UInt8}, n::Int)::Union{HttpMethod,Nothing}
    bad = false
    for i in 1:n
        bad |= @inbounds(TCHAR[unsafe_load(p, i)+1]) == 0x00
    end
    bad && return nothing
    return _m_unchecked(_M_EXTENSION, unsafe_string(p, n))
end

Base.tryparse(::Type{HttpMethod}, p::Ptr{UInt8}, n::Integer) = _tryparse_method(p, Int(n))
@inline Base.tryparse(::Type{HttpMethod}, src::BytesLike) =
    GC.@preserve src _tryparse_method(_ptr(src), _nbytes(src))
Base.tryparse(::Type{HttpMethod}, src::AbstractString) = tryparse(HttpMethod, String(src))
Base.tryparse(::Type{HttpMethod}, src::AbstractVector{UInt8}) = tryparse(HttpMethod, Vector{UInt8}(src))

@noinline _m_throw() = throw(InvalidMethod())

@inline function HttpMethod(src::Union{AbstractString,AbstractVector{UInt8}})
    m = tryparse(HttpMethod, src)
    m === nothing && _m_throw()
    return m
end
@inline function HttpMethod(p::Ptr{UInt8}, n::Integer)
    m = _tryparse_method(p, Int(n))
    m === nothing && _m_throw()
    return m
end
HttpMethod(m::HttpMethod) = m
HttpMethod() = Methods.GET
Base.parse(::Type{HttpMethod}, src::AbstractString) = HttpMethod(src)
Base.convert(::Type{HttpMethod}, src::Union{AbstractString,AbstractVector{UInt8}}) = HttpMethod(src)

"""
    is_safe(m::HttpMethod) -> Bool

Whether the method is safe, that is read-only (RFC 9110 §9.2.1): `GET`, `HEAD`,
`OPTIONS`, `TRACE` and `QUERY`. Extension methods are never safe.

# Examples
```jldoctest
julia> is_safe(Methods.GET), is_safe(Methods.POST), is_safe(HttpMethod("PURGE"))
(true, false, false)
```
"""
is_safe(m::HttpMethod) = m.tag in (0x01, 0x02, 0x06, 0x07, 0x0a)

"""
    is_idempotent(m::HttpMethod) -> Bool

Whether repeating the request has the same effect as sending it once
(RFC 9110 §9.2.2): the safe methods (see [`is_safe`](@ref)) plus `PUT` and
`DELETE`. Extension methods are never idempotent.

# Examples
```jldoctest
julia> is_idempotent(Methods.PUT), is_idempotent(Methods.POST)
(true, false)
```
"""
is_idempotent(m::HttpMethod) = m.tag == 0x04 || m.tag == 0x05 || is_safe(m)

"""
    as_str(x) -> AbstractString

The text of `x` as it appears in an HTTP message, without allocating.

| `x` | Result | Example |
|:--|:--|:--|
| [`HttpMethod`](@ref) | the method token | `"GET"` |
| [`StatusCode`](@ref) | the three digits | `"404"` |
| [`Version`](@ref) | the version string | `"HTTP/1.1"` |
| [`HeaderName`](@ref) | the lowercase name | `"content-type"` |
| [`HeaderValue`](@ref) | the value's bytes, unchecked (see below) | `"text/plain"` |
| [`Scheme`](@ref) | the scheme as written | `"https"` |
| [`Authority`](@ref) | the authority as written | `"example.com:8080"` |
| [`PathAndQuery`](@ref) | path and query; `"/"` when empty | `"/a?x=1"` |
| [`Port`](@ref) | the port as written | `"+80"` |

# Returns
A `String` for methods, status codes, versions, header names and header values;
a `SubString{String}` (a view into the parsed text) for the URI components.

# Notes
- For a `StatusCode`, `string(s)` adds the reason phrase (`"404 Not Found"`);
  `as_str(s)` is the digits only.
- For a `HeaderValue`, `as_str` does not check the bytes; [`to_str`](@ref) does.

# Examples
```jldoctest
julia> as_str(Methods.GET), as_str(StatusCodes.NOT_FOUND), as_str(Versions.HTTP_11)
("GET", "404", "HTTP/1.1")

julia> as_str(header.CONTENT_TYPE), as_str(hv"text/plain")
("content-type", "text/plain")

julia> as_str(Port("+80")), as_str(PathAndQuery("/a?x=1"))
("+80", "/a?x=1")
```
"""
as_str(m::HttpMethod) = getfield(m, :name)

Base.String(m::HttpMethod) = as_str(m)
Base.string(m::HttpMethod) = as_str(m)
Base.print(io::IO, m::HttpMethod) = print(io, as_str(m))
function Base.show(io::IO, m::HttpMethod)
    m.tag == _M_EXTENSION || return print(io, "Methods.", as_str(m))
    print(io, "HttpMethod(")
    show(io, as_str(m))
    print(io, ')')
end

Base.:(==)(a::HttpMethod, b::HttpMethod) = a.tag == b.tag && (a.tag != _M_EXTENSION || a.name == b.name)
Base.:(==)(a::HttpMethod, b::AbstractString) = as_str(a) == b
Base.:(==)(a::AbstractString, b::HttpMethod) = a == as_str(b)
Base.isless(a::HttpMethod, b::HttpMethod) = isless(as_str(a), as_str(b))
Base.hash(m::HttpMethod, h::UInt) = hash(as_str(m), h)
