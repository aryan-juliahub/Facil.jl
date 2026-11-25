# Shared definitions for the uri files, then `Scheme`.

const _U_KINDS = (:InvalidUriChar, :InvalidScheme, :InvalidAuthority, :InvalidPort, :InvalidFormat,
    :SchemeMissing, :AuthorityMissing, :PathAndQueryMissing, :PathDoesNotStartWithSlash,
    :TooLong, :Empty, :SchemeTooLong)
const _U_MESSAGES = ("invalid uri character", "invalid scheme", "invalid authority", "invalid port",
    "invalid format", "scheme missing", "authority missing", "path missing",
    "path does not start with slash", "uri too long", "empty string", "scheme too long")

const _UE_URI_CHAR = 0x01
const _UE_SCHEME = 0x02
const _UE_AUTHORITY = 0x03
const _UE_PORT = 0x04
const _UE_FORMAT = 0x05
const _UE_SCHEME_MISSING = 0x06
const _UE_AUTHORITY_MISSING = 0x07
const _UE_PQ_MISSING = 0x08
const _UE_NO_SLASH = 0x09
const _UE_TOO_LONG = 0x0a
const _UE_EMPTY = 0x0b
const _UE_SCHEME_TOO_LONG = 0x0c

"""
    InvalidUri <: HttpError

A string or byte sequence could not be parsed as a URI component. `kind` is one of
`:InvalidUriChar`, `:InvalidScheme`, `:InvalidAuthority`, `:InvalidPort`, `:InvalidFormat`,
`:SchemeMissing`, `:AuthorityMissing`, `:PathAndQueryMissing`, `:PathDoesNotStartWithSlash`,
`:TooLong`, `:Empty`, `:SchemeTooLong`.
"""
struct InvalidUri <: HttpError
    kind::Symbol
end

"An invalid combination of [`UriParts`](@ref); wraps the [`InvalidUri`](@ref) cause."
struct InvalidUriParts <: HttpError
    err::InvalidUri
end

_u_err(code::UInt8) = InvalidUri(_U_KINDS[code])
_u_message(e::InvalidUri) = _U_MESSAGES[findfirst(==(e.kind), _U_KINDS)::Int]
Base.showerror(io::IO, e::InvalidUri) = print(io, _u_message(e))
Base.showerror(io::IO, e::InvalidUriParts) = print(io, _u_message(e.err))

# u16::MAX is reserved for "no query" in `PathAndQuery`.
const _U_MAX_LEN = 65534
const _U_NONE = 0xffff
const _U_EMPTY = SubString("")

function _u_table(valid)
    t = zeros(UInt8, 256)
    for c in valid
        t[UInt8(c)+1] = UInt8(c)
    end
    return t
end

const _U_ALNUM = ['0':'9'; 'A':'Z'; 'a':'z']
# Valid URI characters map to themselves, all others to 0; every valid entry is ASCII.
const _U_URI_CHARS = _u_table([_U_ALNUM; collect("!#\$&'()*+,-./:;=?@[]_~")])
const _U_SCHEME_CHARS = _u_table([_U_ALNUM; collect("+-.:~")])

@inline _u_byte(s::String, i::Int) = @inbounds codeunit(s, i)
@inline _u_lower(b::UInt8) = b - 0x41 < 0x1a ? b | 0x20 : b

# `off` is a 0-based byte offset; the range must start and end on character boundaries.
@inline _u_sub(s::String, off::Int, n::Int) =
    n == 0 ? _U_EMPTY : SubString(s, off + 1, thisind(s, off + n))

@inline _u_parent(s::String) = (s, 0)
@inline _u_parent(s::SubString{String}) = (parent(s), s.offset)
_u_string(s::Union{String,SubString{String}}) = s
_u_string(s::AbstractString) = String(s)::String
_u_string(v::AbstractVector{UInt8}) = String(Vector{UInt8}(v))

const _USrc = Union{AbstractString,AbstractVector{UInt8}}

# Runs a `(s::String, off, n) -> (error, value)` parser over any accepted source.
@inline function _u_run(f::F, src::_USrc) where {F}
    s = _u_string(src)
    (p, o) = _u_parent(s)
    return f(p, o, ncodeunits(s))
end
@inline function _u_run(f::F, p::Ptr{UInt8}, n::Integer) where {F}
    s = unsafe_string(p, n)
    return f(s, 0, ncodeunits(s))
end
@inline function _u_try(f::F, src...) where {F}
    (code, x) = _u_run(f, src...)
    return code == 0x00 ? x : nothing
end
@inline function _u_must(f::F, src...) where {F}
    (code, x) = _u_run(f, src...)
    code == 0x00 || throw(_u_err(code))
    return x
end

function _u_ci_eq(a::String, ao::Int, b::String, bo::Int, n::Int)
    for i in 1:n
        _u_lower(_u_byte(a, ao + i)) == _u_lower(_u_byte(b, bo + i)) || return false
    end
    return true
end

function _u_ci_eq(a::Union{String,SubString{String}}, b::Union{String,SubString{String}})
    n = ncodeunits(a)
    n == ncodeunits(b) || return false
    (as, ao) = _u_parent(a)
    (bs, bo) = _u_parent(b)
    return _u_ci_eq(as, ao, bs, bo, n)
end

function _u_ci_isless(a::Union{String,SubString{String}}, b::Union{String,SubString{String}})
    (as, ao) = _u_parent(a)
    (bs, bo) = _u_parent(b)
    na, nb = ncodeunits(a), ncodeunits(b)
    for i in 1:min(na, nb)
        x, y = _u_lower(_u_byte(as, ao + i)), _u_lower(_u_byte(bs, bo + i))
        x == y || return x < y
    end
    return na < nb
end

function _u_ci_hash(s::Union{String,SubString{String}}, h::UInt)
    (p, o) = _u_parent(s)
    for i in 1:ncodeunits(s)
        b = _u_byte(p, o + i)
        b - 0x41 < 0x1a && return hash(lowercase(s), h)
    end
    return hash(s, h)
end

# Strict UTF-8 check of bytes `i:j`, as Rust's `str::from_utf8`.
function _u_utf8_ok(s::String, i::Int, j::Int)
    @inline cont(k) = k <= j && _u_byte(s, k) & 0xc0 == 0x80
    @inline inr(k, lo, hi) = k <= j && lo <= _u_byte(s, k) <= hi
    while i <= j
        b = _u_byte(s, i)
        if b < 0x80
            i += 1
        elseif 0xc2 <= b <= 0xdf
            cont(i + 1) || return false
            i += 2
        elseif 0xe0 <= b <= 0xef
            lo, hi = b == 0xe0 ? (0xa0, 0xbf) : b == 0xed ? (0x80, 0x9f) : (0x80, 0xbf)
            (inr(i + 1, lo, hi) && cont(i + 2)) || return false
            i += 3
        elseif 0xf0 <= b <= 0xf4
            lo, hi = b == 0xf0 ? (0x90, 0xbf) : b == 0xf4 ? (0x80, 0x8f) : (0x80, 0xbf)
            (inr(i + 1, lo, hi) && cont(i + 2) && cont(i + 3)) || return false
            i += 4
        else
            return false
        end
    end
    return true
end

"""
    Scheme(src)
    tryparse(Scheme, src)

The scheme component of a URI. `Schemes.HTTP` and `Schemes.HTTPS` are the standard
schemes; `Scheme("ftp")` parses any other. `src` is a string, a byte vector, or a
pointer and length; throws [`InvalidUri`](@ref). Comparison is ASCII case-insensitive.
"""
struct Scheme
    tag::UInt8              # 0x00 none, 0x01 http, 0x02 https, 0x03 other
    other::SubString{String}
    global _u_scheme(tag::UInt8, other::SubString{String}=_U_EMPTY) = new(tag, other)
end

"The standard schemes: `Schemes.HTTP`, `Schemes.HTTPS`."
baremodule Schemes end
Core.eval(Schemes, :(const HTTP = $(_u_scheme(0x01))))
Core.eval(Schemes, :(const HTTPS = $(_u_scheme(0x02))))

const _U_SCHEME_NONE = _u_scheme(0x00)
const _U_HTTP = SubString("http")
const _U_HTTPS = SubString("https")
const _U_MAX_SCHEME_LEN = 64

function _u_scheme_exact(s::String, off::Int, n::Int)::Tuple{UInt8,Scheme}
    n == 4 && _u_ci_eq(s, off, "http", 0, 4) && return (0x00, Schemes.HTTP)
    n == 5 && _u_ci_eq(s, off, "https", 0, 5) && return (0x00, Schemes.HTTPS)
    n > _U_MAX_SCHEME_LEN && return (_UE_SCHEME_TOO_LONG, _U_SCHEME_NONE)
    for i in 1:n
        c = @inbounds _U_SCHEME_CHARS[_u_byte(s, off + i)+1]
        (c == 0x00 || c == UInt8(':')) && return (_UE_SCHEME, _U_SCHEME_NONE)
    end
    return (0x00, _u_scheme(0x03, _u_sub(s, off, n)))
end

# Detects a leading `scheme://`. Returns (error, tag, scheme length).
function _u_scheme_prefix(s::String, off::Int, n::Int)::Tuple{UInt8,UInt8,Int}
    n >= 7 && _u_ci_eq(s, off, "http://", 0, 7) && return (0x00, 0x01, 4)
    n >= 8 && _u_ci_eq(s, off, "https://", 0, 8) && return (0x00, 0x02, 5)
    if n > 3
        for i in 0:n-1
            c = @inbounds _U_SCHEME_CHARS[_u_byte(s, off + i + 1)+1]
            if c == UInt8(':')
                n < i + 3 && break
                (_u_byte(s, off + i + 2) == UInt8('/') && _u_byte(s, off + i + 3) == UInt8('/')) || break
                i > _U_MAX_SCHEME_LEN && return (_UE_SCHEME_TOO_LONG, 0x00, 0)
                return (0x00, 0x03, i)
            elseif c == 0x00
                break
            end
        end
    end
    return (0x00, 0x00, 0)
end

function as_str(s::Scheme)
    s.tag == 0x01 && return _U_HTTP
    s.tag == 0x02 && return _U_HTTPS
    return s.other
end

Base.print(io::IO, s::Scheme) = print(io, as_str(s))
function Base.show(io::IO, s::Scheme)
    s.tag == 0x01 && return print(io, "Schemes.HTTP")
    s.tag == 0x02 && return print(io, "Schemes.HTTPS")
    print(io, "Scheme(")
    show(io, as_str(s))
    print(io, ')')
end
Base.string(s::Scheme) = String(as_str(s))

function Base.:(==)(a::Scheme, b::Scheme)
    a.tag == b.tag || return false
    return a.tag != 0x03 || _u_ci_eq(a.other, b.other)
end
Base.:(==)(a::Scheme, b::AbstractString) = _u_ci_eq(as_str(a), _u_string(b))
Base.:(==)(a::AbstractString, b::Scheme) = b == a

function Base.hash(s::Scheme, h::UInt)
    h = hash(:HttpScheme, h)
    s.tag == 0x03 || return hash(s.tag, h)
    return _u_ci_hash(s.other, h)
end

export Scheme, Schemes, InvalidUri, InvalidUriParts
