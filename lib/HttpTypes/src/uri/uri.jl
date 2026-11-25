"""
    Uri

An HTTP request target or URI: origin-form (`/path?q`), absolute-form
(`http://host/path`), authority-form (`host:443`) or asterisk-form (`*`).
All components are views into one `String`.

    Uri(src)                   # string, bytes, or (ptr, len); throws InvalidUri
    tryparse(Uri, src)         # or nothing
    uri"/static"               # validated at macro expansion
    Uri(; scheme, authority, path_and_query)   # builder; throws InvalidUri / InvalidUriParts
    Uri(parts::UriParts)
    Uri(a::Authority), Uri(pq::PathAndQuery)
"""
struct Uri
    scheme::Scheme                  # tag 0x00 when absent
    authority::Authority            # empty when absent
    path_and_query::PathAndQuery
    global _u_uri(s::Scheme, a::Authority, pq::PathAndQuery) = new(s, a, pq)
end

const _U_DEFAULT = _u_uri(_U_SCHEME_NONE, _U_AUTHORITY_EMPTY, _U_PQ_SLASH)

"""
    UriParts(; scheme=nothing, authority=nothing, path_and_query=nothing)
    UriParts(u::Uri)

The mutable components of a [`Uri`](@ref) (the crate's `uri::Parts`).
"""
mutable struct UriParts
    scheme::Union{Nothing,Scheme}
    authority::Union{Nothing,Authority}
    path_and_query::Union{Nothing,PathAndQuery}
end
UriParts(; scheme=nothing, authority=nothing, path_and_query=nothing) =
    UriParts(scheme, authority, path_and_query)

function _u_parse_uri(s::String, off::Int, n::Int)::Tuple{UInt8,Uri}
    n > _U_MAX_LEN && return (_UE_TOO_LONG, _U_DEFAULT)
    n == 0 && return (_UE_EMPTY, _U_DEFAULT)
    b1 = _u_byte(s, off + 1)
    if n == 1
        b1 == UInt8('/') && return (0x00, _U_DEFAULT)
        b1 == UInt8('*') && return (0x00, _u_uri(_U_SCHEME_NONE, _U_AUTHORITY_EMPTY, _U_PQ_STAR))
        (code, a) = _u_authority_exact(s, off, n)
        return (code, _u_uri(_U_SCHEME_NONE, a, _U_PQ_EMPTY))
    end
    if b1 == UInt8('/')
        (code, pq) = _u_pq_parse(s, off, n)
        return (code, _u_uri(_U_SCHEME_NONE, _U_AUTHORITY_EMPTY, pq))
    end
    return _u_parse_full(s, off, n)
end

function _u_parse_full(s::String, off::Int, n::Int)::Tuple{UInt8,Uri}
    (code, tag, slen) = _u_scheme_prefix(s, off, n)
    code == 0x00 || return (code, _U_DEFAULT)
    sch = tag == 0x00 ? _U_SCHEME_NONE : tag == 0x03 ? _u_scheme(tag, _u_sub(s, off, slen)) : _u_scheme(tag)
    skip = tag == 0x00 ? 0 : slen + 3
    p, m = off + skip, n - skip
    (code, aend) = _u_authority_end(s, p, m)
    code == 0x00 || return (code, _U_DEFAULT)
    if tag == 0x00
        aend == m || return (_UE_FORMAT, _U_DEFAULT)
        return (0x00, _u_uri(sch, _u_authority(_u_sub(s, p, m)), _U_PQ_EMPTY))
    end
    aend == 0 && return (_UE_FORMAT, _U_DEFAULT)
    auth = _u_authority(_u_sub(s, p, aend))
    aend == m && return (0x00, _u_uri(sch, auth, _U_PQ_SLASH))
    (code, pq) = _u_pq_parse(s, p + aend, m - aend)
    return (code, _u_uri(sch, auth, pq))
end

for (T, f) in ((:Scheme, :_u_scheme_exact), (:Authority, :_u_authority_exact),
               (:PathAndQuery, :_u_pq_parse), (:Port, :_u_port_exact), (:Uri, :_u_parse_uri))
    @eval begin
        $T(src::_USrc) = _u_must($f, src)
        $T(p::Ptr{UInt8}, n::Integer) = _u_must($f, p, n)
        Base.tryparse(::Type{$T}, src::_USrc) = _u_try($f, src)
        Base.tryparse(::Type{$T}, p::Ptr{UInt8}, n::Integer) = _u_try($f, p, n)
        Base.parse(::Type{$T}, src::_USrc) = $T(src)
        Base.convert(::Type{$T}, src::_USrc) = $T(src)
    end
end
Base.convert(::Type{Port}, n::Integer) = Port(n)

"""
    HttpTypes.uri_from_target(path_ptr, path_len, query_ptr, query_len) -> Uri

Build a `Uri` from a request target already split into path and query bytes, with one
`String` allocation. Pass `query_len < 0` when the target had no `?`. Throws [`InvalidUri`](@ref).
"""
function uri_from_target(pp::Ptr, pn::Integer, qp::Ptr, qn::Integer)
    pp, qp = Ptr{UInt8}(pp), Ptr{UInt8}(qp)
    pn, qn = Int(pn), Int(qn)
    s = Base._string_n(qn < 0 ? pn : pn + 1 + qn)
    GC.@preserve s begin
        d = pointer(s)
        unsafe_copyto!(d, pp, pn)
        if qn >= 0
            unsafe_store!(d, UInt8('?'), pn + 1)
            unsafe_copyto!(d + pn + 1, qp, qn)
        end
    end
    (code, u) = _u_parse_uri(s, 0, ncodeunits(s))
    code == 0x00 || throw(_u_err(code))
    return u
end

"""
    uri"..."

A `Uri` literal, parsed and validated when the macro expands.
"""
macro uri_str(s)
    return Uri(s)
end

Uri(u::Uri) = u
Uri(a::Authority) = _u_uri(_U_SCHEME_NONE, a, _U_PQ_EMPTY)
Uri(pq::PathAndQuery) = _u_uri(_U_SCHEME_NONE, _U_AUTHORITY_EMPTY, pq)
Base.convert(::Type{Uri}, x::Union{Authority,PathAndQuery}) = Uri(x)

function Uri(parts::UriParts)
    if parts.scheme !== nothing
        parts.authority === nothing && throw(InvalidUriParts(_u_err(_UE_AUTHORITY_MISSING)))
        parts.path_and_query === nothing && throw(InvalidUriParts(_u_err(_UE_PQ_MISSING)))
    elseif parts.authority !== nothing && parts.path_and_query !== nothing
        throw(InvalidUriParts(_u_err(_UE_SCHEME_MISSING)))
    end
    return _u_uri(something(parts.scheme, _U_SCHEME_NONE), something(parts.authority, _U_AUTHORITY_EMPTY),
        something(parts.path_and_query, _U_PQ_EMPTY))
end

_u_has_path(u::Uri) = !isempty(u.path_and_query.data) || u.scheme.tag != 0x00

function UriParts(u::Uri)
    return UriParts(u.scheme.tag == 0x00 ? nothing : u.scheme,
        isempty(u.authority.data) ? nothing : u.authority,
        _u_has_path(u) ? u.path_and_query : nothing)
end

_u_builder_scheme(x::Scheme) = x
_u_builder_scheme(x) = Scheme(x)
_u_builder_authority(x::Authority) = x
_u_builder_authority(x) = Authority(x)
_u_builder_pq(x::PathAndQuery) = x
function _u_builder_pq(x)
    s = _u_string(x)
    (p, o) = _u_parent(s)
    (code, pq) = _u_pq_parse(p, o, ncodeunits(s))
    code == _UE_EMPTY && return _U_PQ_EMPTY
    code == 0x00 || throw(_u_err(code))
    return pq
end

# The crate's `Builder`; with no components given this is `Uri::default()` ("/").
function Uri(; scheme=nothing, authority=nothing, path_and_query=nothing)
    scheme === nothing && authority === nothing && path_and_query === nothing && return _U_DEFAULT
    return Uri(UriParts(scheme === nothing ? nothing : _u_builder_scheme(scheme),
        authority === nothing ? nothing : _u_builder_authority(authority),
        path_and_query === nothing ? nothing : _u_builder_pq(path_and_query)))
end

"The path and query, or `nothing` for an authority-form `Uri`."
path_and_query(u::Uri) =
    (u.scheme.tag != 0x00 || isempty(u.authority.data)) ? u.path_and_query : nothing
path(u::Uri) = _u_has_path(u) ? path(u.path_and_query) : _U_EMPTY
"The [`Scheme`](@ref), or `nothing`."
scheme(u::Uri) = u.scheme.tag == 0x00 ? nothing : u.scheme
"The scheme as a string, or `nothing`."
scheme_str(u::Uri) = u.scheme.tag == 0x00 ? nothing : as_str(u.scheme)
"The [`Authority`](@ref), or `nothing`."
authority(u::Uri) = isempty(u.authority.data) ? nothing : u.authority
host(u::Uri) = isempty(u.authority.data) ? nothing : host(u.authority)
port(u::Uri) = isempty(u.authority.data) ? nothing : port(u.authority)
port_u16(u::Uri) = isempty(u.authority.data) ? nothing : port_u16(u.authority)
query(u::Uri) = query(u.path_and_query)

function Base.print(io::IO, u::Uri)
    sc = scheme(u)
    sc === nothing || print(io, as_str(sc), "://")
    a = authority(u)
    a === nothing || print(io, a.data)
    p = path(u)
    # An absolute-form asterisk target has an empty path; '*' would join the authority.
    (a === nothing || p != "*") && print(io, p)
    q = query(u)
    q === nothing || print(io, '?', q)
    return nothing
end
function Base.show(io::IO, u::Uri)
    print(io, "uri\"")
    Base.escape_raw_string(io, sprint(print, u))
    print(io, '"')
end

_u_opt_eq(a, b) = a === nothing ? b === nothing : (b !== nothing && a == b)

function Base.:(==)(a::Uri, b::Uri)
    return _u_opt_eq(scheme(a), scheme(b)) && _u_opt_eq(authority(a), authority(b)) &&
           path(a) == path(b) && _u_opt_eq(query(a), query(b))
end

function _u_bytes_eq(a::SubString{String}, b::String, bo::Int)
    (s, o) = _u_parent(a)
    for i in 1:ncodeunits(a)
        _u_byte(s, o + i) == _u_byte(b, bo + i) || return false
    end
    return true
end

function _u_eq_str(u::Uri, str::Union{String,SubString{String}})
    (b, p) = _u_parent(str)
    stop = p + ncodeunits(str)
    absolute = false
    sc = scheme(u)
    if sc !== nothing
        name = as_str(sc)
        k = ncodeunits(name)
        absolute = true
        stop - p < k + 3 && return false
        (ns, no) = _u_parent(name)
        _u_ci_eq(ns, no, b, p, k) || return false
        p += k
        (_u_byte(b, p + 1) == UInt8(':') && _u_byte(b, p + 2) == UInt8('/') &&
         _u_byte(b, p + 3) == UInt8('/')) || return false
        p += 3
    end
    a = authority(u)
    if a !== nothing
        k = ncodeunits(a.data)
        absolute = true
        stop - p < k && return false
        (as, ao) = _u_parent(a.data)
        _u_ci_eq(as, ao, b, p, k) || return false
        p += k
    end
    pth = path(u)
    k = ncodeunits(pth)
    if stop - p < k || !_u_bytes_eq(pth, b, p)
        (absolute && pth == "/") || return false
    else
        p += k
    end
    q = query(u)
    if q !== nothing
        p == stop && return isempty(q)
        _u_byte(b, p + 1) == UInt8('?') || return false
        p += 1
        k = ncodeunits(q)
        (stop - p >= k && _u_bytes_eq(q, b, p)) || return false
        p += k
    end
    return p == stop || _u_byte(b, p + 1) == UInt8('#')
end

Base.:(==)(u::Uri, s::AbstractString) = _u_eq_str(u, _u_string(s))
Base.:(==)(s::AbstractString, u::Uri) = u == s

function Base.hash(u::Uri, h::UInt)
    h = hash(:HttpUri, h)
    if u.scheme.tag != 0x00
        h = hash(0xff, hash(u.scheme, h))
    end
    a = authority(u)
    a === nothing || (h = hash(a, h))
    h = hash(path(u), h)
    q = query(u)
    q === nothing || (h = hash(q, hash('?', h)))
    return h
end

export Uri, UriParts, @uri_str, scheme, scheme_str, authority, path_and_query
