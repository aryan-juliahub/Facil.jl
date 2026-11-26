"""
    Port(n::Integer)
    Port(src)
    Port(ptr::Ptr{UInt8}, len::Integer)
    tryparse(Port, src)
    parse(Port, src)

The port of an authority: a number in `0:65535` together with the text it was
written as.

# Arguments
- `n::Integer`: the port number.
- `src`: an `AbstractString` or `AbstractVector{UInt8}` holding decimal digits,
  optionally after a `+`; or a `Port` (returned as is).

# Returns
A `Port`; `tryparse` (which also accepts an integer) returns `nothing` instead
of throwing.

# Throws
- [`InvalidUri`](@ref) with kind `:InvalidPort` for a number outside `0:65535`
  or text that is not such a number.

# Notes
- `UInt16(p)` is the number. `p == 8080` compares with an integer; two ports are
  equal when their numbers are, however they were written.
- [`as_str`](@ref) gives the text as written (`"+80"`, `"080"`); `string` and
  `print` give the number (`"80"`); `show` prints `Port(80)`.

# Examples
```jldoctest
julia> p = Port(8080)
Port(8080)

julia> p == 8080, Int(UInt16(p)), string(p)
(true, 8080, "8080")

julia> q = Port("+80");

julia> as_str(q), string(q)
("+80", "80")

julia> tryparse(Port, 70_000) === nothing
true
```
"""
struct Port
    port::UInt16
    repr::SubString{String}
    global _u_port(port::UInt16, repr::SubString{String}) = new(port, repr)
end

# Rust `u16::from_str`: optional '+', then at least one ASCII digit, no overflow.
function _u_parse_u16(s::String, off::Int, n::Int)::Tuple{Bool,UInt16}
    i = 1
    n >= 1 && _u_byte(s, off + 1) == UInt8('+') && (i = 2)
    i > n && return (false, 0x0000)
    v = 0
    while i <= n
        d = _u_byte(s, off + i) - UInt8('0')
        d > 0x09 && return (false, 0x0000)
        v = 10v + d
        v > 0xffff && return (false, 0x0000)
        i += 1
    end
    return (true, v % UInt16)
end

const _U_PORT_NONE = _u_port(0x0000, _U_EMPTY)

function _u_port_exact(s::String, off::Int, n::Int)::Tuple{UInt8,Port}
    (ok, v) = _u_parse_u16(s, off, n)
    ok || return (_UE_PORT, _U_PORT_NONE)
    return (0x00, _u_port(v, _u_sub(s, off, n)))
end

function Base.tryparse(::Type{Port}, n::Integer)
    0 <= n <= 0xffff || return nothing
    v = n % UInt16
    return _u_port(v, SubString(string(v)))
end
function Port(n::Integer)
    p = tryparse(Port, n)
    p === nothing && throw(_u_err(_UE_PORT))
    return p
end
Port(p::Port) = p

as_str(p::Port) = p.repr
Base.UInt16(p::Port) = p.port

Base.print(io::IO, p::Port) = print(io, Int(p.port))
Base.show(io::IO, p::Port) = print(io, "Port(", Int(p.port), ")")

Base.:(==)(a::Port, b::Port) = a.port == b.port
Base.:(==)(a::Port, b::Integer) = a.port == b
Base.:(==)(a::Integer, b::Port) = a == b.port
Base.hash(p::Port, h::UInt) = hash(p.port, h)

export Port
