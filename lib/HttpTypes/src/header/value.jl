export HeaderValue, InvalidHeaderValue, ToStrError, to_str, is_sensitive, set_sensitive, @hv_str

"""
    InvalidHeaderValue

Thrown when bytes are not a valid header field value.
"""
struct InvalidHeaderValue <: HttpError end
Base.showerror(io::IO, ::InvalidHeaderValue) = print(io, "failed to parse header value")

"""
    ToStrError

Thrown by `to_str` when a header value holds bytes outside visible ASCII.
"""
struct ToStrError <: HttpError end
Base.showerror(io::IO, ::ToStrError) = print(io, "failed to convert header to a str")

"""
    HeaderValue(src)
    tryparse(HeaderValue, src)

A header field value. A string source must be visible ASCII (plus tab); a byte
source (vector, or pointer and length) may also carry opaque bytes 0x80:0xff.
Control bytes and DEL are rejected. `HeaderValue(n)` formats an integer and
`HeaderValue(name)` copies a `HeaderName`.
"""
struct HeaderValue
    data::String
    sensitive::Bool
    global _h_value_unchecked(data::String, sensitive::Bool=false) = new(data, sensitive)
end

@inline _h_valid_ascii(b::UInt8) = (b >= 0x20) & (b < 0x7f) | (b == 0x09)
@inline _h_valid_opaque(b::UInt8) = (b >= 0x20) & (b != 0x7f) | (b == 0x09)

# No early return, so the loop vectorizes.
@inline function _h_all_valid(valid::F, p::Ptr{UInt8}, n::Int) where {F}
    bad = false
    for i in 1:n
        bad |= !valid(_load(p, i))
    end
    return !bad
end

function Base.tryparse(::Type{HeaderValue}, src::String)
    ok = GC.@preserve src _h_all_valid(_h_valid_ascii, pointer(src), sizeof(src))
    return ok ? _h_value_unchecked(src) : nothing
end
function Base.tryparse(::Type{HeaderValue}, src::SubString{String})
    GC.@preserve src begin
        _h_all_valid(_h_valid_ascii, pointer(src), sizeof(src)) || return nothing
        return _h_value_unchecked(unsafe_string(pointer(src), sizeof(src)))
    end
end
Base.tryparse(::Type{HeaderValue}, src::AbstractString) = tryparse(HeaderValue, String(src))
@inline function Base.tryparse(::Type{HeaderValue}, p::Ptr{UInt8}, n::Integer)
    _h_all_valid(_h_valid_opaque, p, Int(n)) || return nothing
    return _h_value_unchecked(unsafe_string(p, n))
end
@inline Base.tryparse(::Type{HeaderValue}, src::DenseBytes) =
    GC.@preserve src tryparse(HeaderValue, _ptr(src), _nbytes(src))
Base.tryparse(::Type{HeaderValue}, src::AbstractVector{UInt8}) = tryparse(HeaderValue, Vector{UInt8}(src))

@inline function HeaderValue(src::Union{AbstractString,AbstractVector{UInt8}})
    v = tryparse(HeaderValue, src)
    v === nothing && throw(InvalidHeaderValue())
    return v
end
@inline function HeaderValue(p::Ptr{UInt8}, n::Integer)
    v = tryparse(HeaderValue, p, n)
    v === nothing && throw(InvalidHeaderValue())
    return v
end
HeaderValue(v::HeaderValue) = v

# The crate converts these integer types; 8-bit ones are left out on purpose.
const _H_INT_VALUE = Union{Int16,UInt16,Int32,UInt32,Int64,UInt64}
HeaderValue(n::_H_INT_VALUE) = _h_value_unchecked(string(n))
HeaderValue(h::HeaderName) = _h_value_unchecked(as_str(h))
Base.parse(::Type{HeaderValue}, src::Union{AbstractString,AbstractVector{UInt8}}) = HeaderValue(src)
Base.convert(::Type{HeaderValue},
    src::Union{AbstractString,AbstractVector{UInt8},HeaderName,_H_INT_VALUE}) = HeaderValue(src)

"""
    from_static(HeaderValue, s)

A `HeaderValue` from a visible-ASCII literal. Prefer `hv"..."`, which checks it
when the code is parsed.
"""
from_static(::Type{HeaderValue}, src::String) = HeaderValue(src)

"`hv\"text/plain\"` is a `HeaderValue` validated when the code is parsed."
macro hv_str(s)
    return from_static(HeaderValue, s)
end

"""
    HttpTypes.unchecked(HeaderValue, p, n)
    HttpTypes.unchecked(HeaderValue, s::String)

A `HeaderValue` holding these bytes without validating them. For bytes a parser
has already checked.
"""
unchecked(::Type{HeaderValue}, p::Ptr{UInt8}, n::Integer) = _h_value_unchecked(unsafe_string(p, n))
unchecked(::Type{HeaderValue}, s::String) = _h_value_unchecked(s)

"""
    to_str(v::HeaderValue)

The value as a `String`; throws `ToStrError` unless it is all visible ASCII.
"""
function to_str(v::HeaderValue)
    s = getfield(v, :data)
    ok = GC.@preserve s _h_all_valid(_h_valid_ascii, pointer(s), sizeof(s))
    ok || throw(ToStrError())
    return s
end

"""
    as_str(v::HeaderValue)
    String(v::HeaderValue)

The value's bytes as a `String`, unchecked (opaque bytes 0x80:0xff included). See `to_str`.
"""
as_str(v::HeaderValue) = getfield(v, :data)
Base.String(v::HeaderValue) = getfield(v, :data)

"Whether the value is marked sensitive (its bytes are never shown, and it is kept out of HPACK tables)."
is_sensitive(v::HeaderValue) = getfield(v, :sensitive)
"`set_sensitive(v, flag)` is `v` with the sensitive mark set to `flag`."
set_sensitive(v::HeaderValue, flag::Bool) = _h_value_unchecked(getfield(v, :data), flag)

Base.codeunits(v::HeaderValue) = codeunits(getfield(v, :data))
Base.sizeof(v::HeaderValue) = sizeof(getfield(v, :data))
Base.length(v::HeaderValue) = sizeof(getfield(v, :data))
Base.isempty(v::HeaderValue) = sizeof(getfield(v, :data)) == 0

Base.:(==)(a::HeaderValue, b::HeaderValue) = getfield(a, :data) == getfield(b, :data)
Base.:(==)(a::HeaderValue, b::AbstractString) = getfield(a, :data) == b
Base.:(==)(a::AbstractString, b::HeaderValue) = a == getfield(b, :data)
Base.:(==)(a::HeaderValue, b::AbstractVector{UInt8}) = codeunits(a) == b
Base.:(==)(a::AbstractVector{UInt8}, b::HeaderValue) = b == a
Base.isless(a::HeaderValue, b::HeaderValue) = isless(getfield(a, :data), getfield(b, :data))
Base.isless(a::HeaderValue, b::AbstractString) = isless(getfield(a, :data), b)
Base.isless(a::AbstractString, b::HeaderValue) = isless(a, getfield(b, :data))
Base.hash(v::HeaderValue, h::UInt) = hash(getfield(v, :data), hash(:HeaderValue, h))

# Sensitive values never show their bytes; others show as a literal that parses back.
function Base.show(io::IO, v::HeaderValue)
    is_sensitive(v) && return print(io, "HeaderValue(<sensitive>)")
    s = getfield(v, :data)
    if GC.@preserve s _h_all_valid(b -> 0x20 <= b < 0x7f, pointer(s), sizeof(s))
        print(io, "hv\"")
        Base.escape_raw_string(io, s)
        print(io, '"')
    elseif GC.@preserve s _h_all_valid(_h_valid_ascii, pointer(s), sizeof(s))
        print(io, "HeaderValue(")
        show(io, s)
        print(io, ')')
    else
        print(io, "HeaderValue(codeunits(")
        show(io, s)
        print(io, "))")
    end
end
Base.print(io::IO, v::HeaderValue) = print(io, getfield(v, :data))
