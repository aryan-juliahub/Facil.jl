export HttpMethod, Methods, InvalidMethod, is_safe, is_idempotent, as_str

"""
    InvalidMethod

Thrown when bytes are not a valid HTTP method token.
"""
struct InvalidMethod <: HttpError end
Base.showerror(io::IO, ::InvalidMethod) = print(io, "invalid HTTP method")

"""
    HttpMethod(src)
    tryparse(HttpMethod, src)

The request method. Standard methods are interned constants (`Methods.GET`, ...);
any other RFC 9110 token is an extension method. `src` is a string, a byte vector,
or a pointer and length. The default is `Methods.GET`.
"""
struct HttpMethod
    tag::UInt8
    name::String
    global _m_unchecked(tag::UInt8, name::String) = new(tag, name)
end

const _M_NAMES = ("OPTIONS", "GET", "POST", "PUT", "DELETE", "HEAD", "TRACE", "CONNECT", "PATCH", "QUERY")
const _M_EXTENSION = 0x00

"The standard methods: `Methods.GET`, `Methods.POST`, ..., `Methods.QUERY`."
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

"Whether the method is safe (RFC 9110 §9.2.1): GET, HEAD, OPTIONS, TRACE, QUERY."
is_safe(m::HttpMethod) = m.tag in (0x01, 0x02, 0x06, 0x07, 0x0a)

"Whether the method is idempotent (RFC 9110 §9.2.2): the safe methods plus PUT and DELETE."
is_idempotent(m::HttpMethod) = m.tag == 0x04 || m.tag == 0x05 || is_safe(m)

"""
    as_str(x)

The textual form of `x` without allocating: the method token of an `HttpMethod`
(`"GET"`), the three digits of a `StatusCode` (`"404"`), the lowercase name of a
`HeaderName`, a `Version` (`"HTTP/1.1"`), or the text of a `Scheme`, `Authority`,
`PathAndQuery` (`"/"` when empty) or `Port` (as written, e.g. `"+80"`).
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
