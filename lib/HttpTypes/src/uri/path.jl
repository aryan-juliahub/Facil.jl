"""
    PathAndQuery(src)
    tryparse(PathAndQuery, src)

The path and query components of a URI (`/a/b?x=1`). `src` is a string, a byte vector,
or a pointer and length that starts with `/` (or is `*`); throws [`InvalidUri`](@ref).
Any fragment is dropped when parsing.
"""
struct PathAndQuery
    data::SubString{String}
    query::UInt16           # 0-based offset of '?' in `data`, or 0xffff for none
    global _u_pq(data::SubString{String}, query::UInt16) = new(data, query)
end

const _U_PQ_EMPTY = _u_pq(_U_EMPTY, _U_NONE)
const _U_PQ_SLASH = _u_pq(SubString("/"), _U_NONE)
const _U_PQ_STAR = _u_pq(SubString("*"), _U_NONE)

const _UC_VALID = 0x00
const _UC_QUERY = 0x01
const _UC_FRAGMENT = 0x02
const _UC_HIGH = 0x03
const _UC_INVALID = 0x04

function _u_class_map(valid)
    t = fill(_UC_INVALID, 256)
    for b in 0x00:0xff
        t[b+1] = b >= 0x80 ? _UC_HIGH : valid(b) ? _UC_VALID : _UC_INVALID
    end
    t[UInt8('#')+1] = _UC_FRAGMENT
    return t
end

# WHATWG path-state bytes, plus '"', '{' and '}' accepted as sent by real clients.
const _U_PATH_MAP = let t = _u_class_map(b -> b == 0x21 || 0x24 <= b <= 0x3b || b == 0x3d ||
        0x40 <= b <= 0x5f || 0x61 <= b <= 0x7a || b == 0x7c || b == 0x7e || b in (0x22, 0x7b, 0x7d))
    t[UInt8('?')+1] = _UC_QUERY
    t
end
const _U_QUERY_MAP = _u_class_map(b -> b == 0x21 || 0x24 <= b <= 0x3b || b == 0x3d || 0x3f <= b <= 0x7e)

# Scans bytes as path-and-query. Returns (error, data length without fragment, query offset).
function _u_scan_pq(s::String, off::Int, n::Int)::Tuple{UInt8,Int,UInt16}
    n == 0 && return (_UE_EMPTY, 0, _U_NONE)
    n > _U_MAX_LEN && return (_UE_TOO_LONG, 0, _U_NONE)
    b1 = _u_byte(s, off + 1)
    n == 1 && b1 == UInt8('*') && return (0x00, 1, _U_NONE)
    (b1 == UInt8('/') || b1 == UInt8('?') || b1 == UInt8('#')) || return (_UE_NO_SLASH, 0, _U_NONE)
    query = _U_NONE
    stop = n
    high = false
    i = 0
    while i < n
        c = @inbounds _U_PATH_MAP[_u_byte(s, off + i + 1)+1]
        if c == _UC_VALID
        elseif c == _UC_QUERY
            query = i % UInt16
            i += 1
            break
        elseif c == _UC_FRAGMENT
            stop = i
            break
        elseif c == _UC_HIGH
            high = true
        else
            return (_UE_URI_CHAR, 0, _U_NONE)
        end
        i += 1
    end
    if query != _U_NONE
        while i < n
            c = @inbounds _U_QUERY_MAP[_u_byte(s, off + i + 1)+1]
            if c == _UC_VALID
            elseif c == _UC_HIGH
                high = true
            elseif c == _UC_FRAGMENT
                stop = i
                break
            else
                return (_UE_URI_CHAR, 0, _U_NONE)
            end
            i += 1
        end
    end
    high && !_u_utf8_ok(s, off + 1, off + stop) && return (_UE_URI_CHAR, 0, _U_NONE)
    return (0x00, stop, query)
end

function _u_pq_parse(s::String, off::Int, n::Int)::Tuple{UInt8,PathAndQuery}
    (code, stop, query) = _u_scan_pq(s, off, n)
    code == 0x00 || return (code, _U_PQ_EMPTY)
    return (0x00, _u_pq(_u_sub(s, off, stop), query))
end

"""
    path(pq::PathAndQuery)
    path(u::Uri)

The path, without query. An empty path reads as `"/"`, except for a `Uri` that is
authority-only, which has path `""`.
"""
function path end

function path(pq::PathAndQuery)
    d = pq.data
    if pq.query != _U_NONE
        (s, o) = _u_parent(d)
        d = _u_sub(s, o, Int(pq.query))
    end
    return isempty(d) ? _U_PQ_SLASH.data : d
end

"""
    query(pq::PathAndQuery)
    query(u::Uri)

The query after `?` (possibly empty), or `nothing` when there is no `?`.
"""
function query end

function query(pq::PathAndQuery)
    pq.query == _U_NONE && return nothing
    d = pq.data
    (s, o) = _u_parent(d)
    q = Int(pq.query) + 1
    return _u_sub(s, o + q, ncodeunits(d) - q)
end

as_str(pq::PathAndQuery) = isempty(pq.data) ? _U_PQ_SLASH.data : pq.data

function Base.print(io::IO, pq::PathAndQuery)
    d = pq.data
    if isempty(d)
        print(io, '/')
    else
        b = codeunit(d, 1)
        (b == UInt8('/') || b == UInt8('*')) || print(io, '/')
        print(io, d)
    end
    return nothing
end
Base.show(io::IO, pq::PathAndQuery) = (print(io, "PathAndQuery("); show(io, sprint(print, pq)); print(io, ')'))

Base.:(==)(a::PathAndQuery, b::PathAndQuery) = a.data == b.data
Base.:(==)(a::PathAndQuery, b::AbstractString) = as_str(a) == b
Base.:(==)(a::AbstractString, b::PathAndQuery) = a == as_str(b)
Base.isless(a::PathAndQuery, b::PathAndQuery) = isless(as_str(a), as_str(b))
Base.isless(a::PathAndQuery, b::AbstractString) = isless(as_str(a), b)
Base.isless(a::AbstractString, b::PathAndQuery) = isless(a, as_str(b))
Base.hash(pq::PathAndQuery, h::UInt) = hash(pq.data, hash(:HttpPathAndQuery, h))

export PathAndQuery, path, query
