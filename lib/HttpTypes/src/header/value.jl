export HeaderValue, InvalidHeaderValue, ToStrError, to_str, is_sensitive, set_sensitive, @hv_str

"""
    InvalidHeaderValue <: HttpError

Thrown by [`HeaderValue`](@ref), and by every [`HeaderMap`](@ref) function that
converts a value, when the source holds a forbidden byte: a control byte other
than tab, DEL, or (for a string source) any non-ASCII byte. Line breaks are
control bytes, so a value can never span lines. The message is
`failed to parse header value`.

# Examples
```jldoctest
julia> HeaderValue("café")
ERROR: failed to parse header value
[...]
```
"""
struct InvalidHeaderValue <: HttpError end
Base.showerror(io::IO, ::InvalidHeaderValue) = print(io, "failed to parse header value")

"""
    ToStrError <: HttpError

Thrown by [`to_str`](@ref) when a [`HeaderValue`](@ref) holds a byte outside
visible ASCII (and tab). The message is `failed to convert header to a str`.

# Examples
```jldoctest
julia> to_str(HeaderValue(UInt8[0xff]))
ERROR: failed to convert header to a str
[...]
```
"""
struct ToStrError <: HttpError end
Base.showerror(io::IO, ::ToStrError) = print(io, "failed to convert header to a str")

"""
    HeaderValue(src)
    HeaderValue(ptr::Ptr{UInt8}, len::Integer)
    HeaderValue(n::Integer)
    HeaderValue(name::HeaderName)
    tryparse(HeaderValue, src)
    parse(HeaderValue, src)

A header field value.

# Arguments
- `src`: the value.
  - An `AbstractString` must be visible ASCII (`0x20:0x7e`) or tab.
  - An `AbstractVector{UInt8}` (or `ptr`, `len`) may also hold the opaque bytes
    `0x80:0xff`, so values in other encodings can be carried through.
  - A `HeaderValue` is returned as is.
- `n::Integer`: formatted in decimal. Accepted types are `Int16`, `UInt16`,
  `Int32`, `UInt32`, `Int64` and `UInt64`; other integer types are a `MethodError`.
- `name::HeaderName`: the name's text becomes the value (useful for headers such
  as `vary` and `access-control-allow-headers`).

# Returns
A `HeaderValue`. `tryparse` returns `nothing` instead of throwing. The empty
string is a valid value.

# Throws
- [`InvalidHeaderValue`](@ref) for control bytes (including CR and LF) and DEL,
  and for non-ASCII bytes in a string source.

# Notes
- `v == "text/plain"` compares with a string and `v == bytes` with a byte vector.
  Values order (`isless`) by their bytes. `hash(v)` differs from the hash of the
  equal string.
- [`as_str`](@ref), `String(v)`, `string(v)` and `print` give the bytes without
  checking them; [`to_str`](@ref) throws unless they are visible ASCII.
- `length(v)` and `sizeof(v)` are the number of bytes; `codeunits(v)` views them.
- `show` prints the literal `hv"text/plain"`, a constructor call for values the
  literal cannot express, and `HeaderValue(<sensitive>)` for a value marked with
  [`set_sensitive`](@ref).
- `convert(HeaderValue, x)` accepts everything the constructor does, so header
  collections take plain strings and integers.

# Examples
```jldoctest
julia> HeaderValue("text/plain")
hv"text/plain"

julia> HeaderValue(1024)
hv"1024"

julia> HeaderValue(header.ACCEPT_ENCODING)
hv"accept-encoding"

julia> v = HeaderValue(UInt8[0x63, 0x61, 0x66, 0xe9]);

julia> length(v), tryparse(HeaderValue, "line\\nbreak") === nothing
(4, true)
```

See also [`hv"..."`](@ref @hv_str), [`is_sensitive`](@ref).
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

from_static(::Type{HeaderValue}, src::String) = HeaderValue(src)

"""
    hv"value"

A [`HeaderValue`](@ref) literal, checked when the code is parsed.

The text must be visible ASCII (tabs allowed); anything else is an error at
macro expansion ([`InvalidHeaderValue`](@ref)), before the program runs.

# Examples
```jldoctest
julia> hv"application/json"
hv"application/json"

julia> hv"application/json" == "application/json"
true
```
"""
macro hv_str(s)
    return from_static(HeaderValue, s)
end

"""
    HttpTypes.unchecked(HeaderValue, ptr::Ptr{UInt8}, len::Integer) -> HeaderValue
    HttpTypes.unchecked(HeaderValue, s::String) -> HeaderValue

A [`HeaderValue`](@ref) holding these bytes without validating them.
Not exported.

For bytes that an HTTP parser has already checked. Passing bytes that
`HeaderValue(src)` would reject (CR, LF, other control bytes) produces a value
that can corrupt the message it is written into, so never use it on input that
has not been validated. The pointer form copies the bytes; the `String` form
shares the string.

# Examples
```jldoctest
julia> HttpTypes.unchecked(HeaderValue, "text/plain") == hv"text/plain"
true
```
"""
unchecked(::Type{HeaderValue}, p::Ptr{UInt8}, n::Integer) = _h_value_unchecked(unsafe_string(p, n))
unchecked(::Type{HeaderValue}, s::String) = _h_value_unchecked(s)

"""
    to_str(v::HeaderValue) -> String

The value as a `String`, after checking that every byte is visible ASCII or tab.

Use it when the text will be parsed or shown; use [`as_str`](@ref) when the raw
bytes are wanted. No copy is made.

# Throws
- [`ToStrError`](@ref) if the value holds an opaque byte (`0x80:0xff`).

# Examples
```jldoctest
julia> to_str(hv"text/plain")
"text/plain"

julia> to_str(HeaderValue(UInt8[0x63, 0x61, 0x66, 0xe9]))
ERROR: failed to convert header to a str
[...]
```
"""
function to_str(v::HeaderValue)
    s = getfield(v, :data)
    ok = GC.@preserve s _h_all_valid(_h_valid_ascii, pointer(s), sizeof(s))
    ok || throw(ToStrError())
    return s
end

"""
    as_str(v::HeaderValue) -> String
    String(v::HeaderValue) -> String

The value's bytes as a `String`, without checking them and without a copy.

A value built from bytes may hold opaque bytes (`0x80:0xff`), so the result is
not always valid UTF-8. [`to_str`](@ref) is the checked form.

# Examples
```jldoctest
julia> as_str(hv"gzip, br")
"gzip, br"

julia> isvalid(as_str(HeaderValue(UInt8[0x63, 0x61, 0x66, 0xe9])))
false
```
"""
as_str(v::HeaderValue) = getfield(v, :data)
Base.String(v::HeaderValue) = getfield(v, :data)

"""
    is_sensitive(v::HeaderValue) -> Bool

Whether the value is marked sensitive with [`set_sensitive`](@ref). A new value
is not sensitive.

# Examples
```jldoctest
julia> is_sensitive(hv"secret"), is_sensitive(set_sensitive(hv"secret", true))
(false, true)
```
"""
is_sensitive(v::HeaderValue) = getfield(v, :sensitive)
"""
    set_sensitive(v::HeaderValue, flag::Bool) -> HeaderValue

A copy of `v` with the sensitive mark set to `flag`. `v` itself is not changed
(header values are immutable), so store the result.

The mark is a hint for whoever handles the value: `show` and `repr` print
`HeaderValue(<sensitive>)` instead of the bytes, so the value stays out of logs
that print a request, a response or a header map, and an HTTP/2 encoder should
keep it out of its compression table.

!!! warning
    Only `show` hides the bytes. `print`, `string`, `String`, [`as_str`](@ref)
    and [`to_str`](@ref) still return them. The mark does not take part in `==`
    or `hash`.

# Examples
```jldoctest
julia> token = set_sensitive(HeaderValue("Bearer abc123"), true)
HeaderValue(<sensitive>)

julia> HeaderMap(header.AUTHORIZATION => token)
HeaderMap(hn"authorization" => HeaderValue(<sensitive>))

julia> as_str(token)
"Bearer abc123"
```
"""
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
# A value hashes as a `HeaderValue`, so it is never `isequal` to the string or
# bytes it compares `==` to, and never the same `Dict` key.
Base.isequal(::HeaderValue, ::Union{AbstractString,AbstractVector{UInt8}}) = false
Base.isequal(::Union{AbstractString,AbstractVector{UInt8}}, ::HeaderValue) = false
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
