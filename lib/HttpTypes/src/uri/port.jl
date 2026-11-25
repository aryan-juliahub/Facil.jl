"""
    Port(src)
    tryparse(Port, src)

The port of an authority: its numeric value and its textual form (`as_str`). `src` is
an integer in `0:65535`, or a string, byte vector, or pointer and length holding an
optional `+` and decimal digits; throws [`InvalidUri`](@ref) with kind `:InvalidPort`.
Compares equal to other `Port`s and to integers by value; `UInt16(p)` is the number.
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
