"""
    PathAndQuery(src)
    PathAndQuery(ptr::Ptr{UInt8}, len::Integer)
    tryparse(PathAndQuery, src)
    parse(PathAndQuery, src)

The path and query of a URI: `/a/b?x=1`.

# Arguments
- `src`: an `AbstractString` or `AbstractVector{UInt8}` that starts with `/`, or
  is `*`.
- `ptr`, `len`: a pointer to `len` bytes holding the same.

# Returns
A `PathAndQuery`; `tryparse` returns `nothing` instead of throwing.
[`path`](@ref) and [`query`](@ref) read its two halves.

# Throws
- [`InvalidUri`](@ref): `:Empty`, `:PathDoesNotStartWithSlash`,
  `:InvalidUriChar` (space, control bytes, invalid UTF-8) or `:TooLong`.

# Notes
- A fragment (`#...`) is dropped when parsing.
- Nothing is percent-decoded or normalised: `%20`, `..` and `//` stay as
  written, and comparison is byte for byte.
- [`as_str`](@ref), `string` and `print` give the text; `show` prints
  `PathAndQuery("/a?x=1")`.

# Examples
```jldoctest
julia> pq = PathAndQuery("/search?q=julia#top")
PathAndQuery("/search?q=julia")

julia> path(pq), query(pq)
("/search", "q=julia")

julia> PathAndQuery("search")
ERROR: path does not start with slash
[...]
```
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
    path(pq::PathAndQuery) -> SubString{String}
    path(u::Uri) -> SubString{String}

The path, without the query.

# Returns
The path as written: not percent-decoded and not normalised. An empty path
reads as `"/"`, except for an authority-form [`Uri`](@ref) (`example.com:443`),
whose path is `""`. The asterisk-form target has path `"*"`.

# Examples
```jldoctest
julia> path(uri"/users/42?full=1")
"/users/42"

julia> path(uri"https://example.com")
"/"

julia> path(uri"/a%20b")
"/a%20b"

julia> path(Uri("example.com:443"))
""
```
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
    query(pq::PathAndQuery) -> Union{SubString{String},Nothing}
    query(u::Uri) -> Union{SubString{String},Nothing}

The query: what follows the first `?`.

# Returns
The raw query text, without the `?`, not split into parameters and not
percent-decoded. `nothing` when there is no `?`; an empty string when the `?`
is there but nothing follows it.

# Examples
```jldoctest
julia> query(uri"/search?q=julia&page=2")
"q=julia&page=2"

julia> query(uri"/search?")
""

julia> query(uri"/search") === nothing
true
```
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
