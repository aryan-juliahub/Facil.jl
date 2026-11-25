"""
    Authority(src)
    tryparse(Authority, src)

The authority component of a URI: `[userinfo@]host[:port]`. `src` is a string, a byte
vector, or a pointer and length, and must be the whole authority (no scheme, path, query
or fragment); throws [`InvalidUri`](@ref). Comparison and hashing are ASCII case-insensitive.
"""
struct Authority
    data::SubString{String}
    global _u_authority(data::SubString{String}) = new(data)
end

const _U_AUTHORITY_EMPTY = _u_authority(_U_EMPTY)

# Returns (error, end) where `end` is the length of the authority prefix of the bytes:
# everything before the first '/', '?' or '#'.
function _u_authority_end(s::String, off::Int, n::Int)::Tuple{UInt8,Int}
    n == 0 && return (_UE_EMPTY, 0)
    colon_cnt = 0
    start_bracket = false
    end_bracket = false
    has_percent = false
    stop = n
    at_sign_pos = n
    i = 0
    while i < n
        b = _u_byte(s, off + i + 1)
        ch = @inbounds _U_URI_CHARS[b+1]
        if ch == UInt8('/') || ch == UInt8('?') || ch == UInt8('#')
            stop = i
            break
        end
        if ch == 0x00
            # '%' may belong to the userinfo or an IPv6 zone id; cleared once that is known.
            b == UInt8('%') || return (_UE_URI_CHAR, 0)
            has_percent = true
        elseif ch == UInt8(':')
            colon_cnt >= 8 && return (_UE_AUTHORITY, 0)
            colon_cnt += 1
        elseif ch == UInt8('[')
            (has_percent || start_bracket) && return (_UE_AUTHORITY, 0)
            start_bracket = true
        elseif ch == UInt8(']')
            (!start_bracket || end_bracket) && return (_UE_AUTHORITY, 0)
            end_bracket = true
            colon_cnt = 0
            has_percent = false
        elseif ch == UInt8('@')
            at_sign_pos = i
            colon_cnt = 0
            has_percent = false
        end
        i += 1
    end
    start_bracket != end_bracket && return (_UE_AUTHORITY, 0)
    colon_cnt > 1 && return (_UE_AUTHORITY, 0)
    stop > 0 && at_sign_pos == stop - 1 && return (_UE_AUTHORITY, 0)
    has_percent && return (_UE_AUTHORITY, 0)
    return (0x00, stop)
end

function _u_authority_exact(s::String, off::Int, n::Int)::Tuple{UInt8,Authority}
    (code, stop) = _u_authority_end(s, off, n)
    code == 0x00 || return (code, _U_AUTHORITY_EMPTY)
    stop == n || return (_UE_URI_CHAR, _U_AUTHORITY_EMPTY)
    return (0x00, _u_authority(_u_sub(s, off, n)))
end

as_str(a::Authority) = a.data

"""
    host(a::Authority)
    host(u::Uri)

The host subcomponent: after any `userinfo@`, before any `:port`. IPv6 hosts keep
their brackets. For a `Uri` without authority, returns `nothing`.
"""
function host end

function host(a::Authority)
    d = a.data
    (s, o) = _u_parent(d)
    n = ncodeunits(d)
    st = 0
    for i in n:-1:1
        if _u_byte(s, o + i) == UInt8('@')
            st = i
            break
        end
    end
    st < n || return _U_EMPTY
    delim = _u_byte(s, o + st + 1) == UInt8('[') ? UInt8(']') : UInt8(':')
    stop = n
    for i in st+1:n
        if _u_byte(s, o + i) == delim
            stop = delim == UInt8(']') ? i : i - 1
            break
        end
    end
    return _u_sub(s, o + st, stop - st)
end

"""
    port(a::Authority)
    port(u::Uri)

The [`Port`](@ref) after the last `:`, or `nothing` when absent or not a valid u16.
For a `Uri` without authority, returns `nothing`.
"""
function port end

function port(a::Authority)
    d = a.data
    (s, o) = _u_parent(d)
    n = ncodeunits(d)
    for i in n:-1:1
        if _u_byte(s, o + i) == UInt8(':')
            (ok, v) = _u_parse_u16(s, o + i, n - i)
            return ok ? _u_port(v, _u_sub(s, o + i, n - i)) : nothing
        end
    end
    return nothing
end

"""
    port_u16(a::Authority)
    port_u16(u::Uri)

The port as a `UInt16`, or `nothing` when [`port`](@ref) is `nothing`.
"""
function port_u16 end

function port_u16(a::Authority)
    p = port(a)
    return p === nothing ? nothing : p.port
end

Base.print(io::IO, a::Authority) = print(io, a.data)
Base.show(io::IO, a::Authority) = (print(io, "Authority("); show(io, a.data); print(io, ')'))
Base.string(a::Authority) = String(a.data)

Base.:(==)(a::Authority, b::Authority) = _u_ci_eq(a.data, b.data)
Base.:(==)(a::Authority, b::AbstractString) = _u_ci_eq(a.data, _u_string(b))
Base.:(==)(a::AbstractString, b::Authority) = b == a
Base.isless(a::Authority, b::Authority) = _u_ci_isless(a.data, b.data)
Base.isless(a::Authority, b::AbstractString) = _u_ci_isless(a.data, _u_string(b))
Base.isless(a::AbstractString, b::Authority) = _u_ci_isless(_u_string(a), b.data)
Base.hash(a::Authority, h::UInt) = _u_ci_hash(a.data, hash(:HttpAuthority, h))

export Authority, host, port, port_u16
