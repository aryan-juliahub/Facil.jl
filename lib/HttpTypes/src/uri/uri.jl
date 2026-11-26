"""
    Uri(src)
    Uri(ptr::Ptr{UInt8}, len::Integer)
    Uri(; scheme = nothing, authority = nothing, path_and_query = nothing)
    Uri(parts::UriParts)
    Uri(a::Authority)
    Uri(pq::PathAndQuery)
    tryparse(Uri, src)
    parse(Uri, src)

A URI as used in HTTP: the request target of a [`Request`](@ref).

Four forms parse:

| Form | Example | Used for |
|:--|:--|:--|
| origin | `/users/42?full=1` | ordinary requests to a server |
| absolute | `https://example.com/users/42` | requests to a proxy, client-side URLs |
| authority | `example.com:443` | `CONNECT` |
| asterisk | `*` | `OPTIONS *` |

# Arguments
- `src`: an `AbstractString` or `AbstractVector{UInt8}`, at most 65,534 bytes; or
  a `Uri` (returned as is).
- `scheme`, `authority`, `path_and_query`: components for the keyword form, each
  a string or an already-parsed [`Scheme`](@ref), [`Authority`](@ref) or
  [`PathAndQuery`](@ref). With no keywords the result is `uri"/"`.
- `parts`: a [`UriParts`](@ref).

# Returns
An immutable `Uri`. `tryparse` returns `nothing` instead of throwing. Read it
with [`scheme`](@ref), [`authority`](@ref), [`host`](@ref), [`port`](@ref),
[`path`](@ref), [`query`](@ref) and [`path_and_query`](@ref).

# Throws
- [`InvalidUri`](@ref) if `src` or a keyword component does not parse.
- [`InvalidUriParts`](@ref) if the components do not combine: a scheme needs an
  authority and a path; an authority with a path needs a scheme.

# Notes
- Nothing is percent-decoded or normalised, and a fragment (`#...`) is dropped.
- A relative reference without a leading slash (`"a/b"`) does not parse as a
  path; it is read as an authority or rejected.
- A port that is not a number in `0:65535` does not make the URI invalid;
  [`port`](@ref) is then `nothing`.
- `==` and `hash` work component by component: scheme and authority ignoring
  ASCII case, path and query exactly. `u == "..."` compares with a string the
  same way, ignoring any fragment in the string.
- `string(u)` and `print` give the text; `show` prints the literal `uri"..."`.
- For a literal, [`uri"..."`](@ref @uri_str) validates when the code is parsed.

# Examples
```jldoctest
julia> u = Uri("https://example.com:8443/users/42?full=1")
uri"https://example.com:8443/users/42?full=1"

julia> scheme(u), host(u), port(u), path(u), query(u)
(Schemes.HTTPS, "example.com", Port(8443), "/users/42", "full=1")

julia> t = Uri("/users/42?full=1");

julia> host(t) === nothing, path(t)
(true, "/users/42")

julia> Uri(; scheme = "https", authority = "example.com", path_and_query = "/x")
uri"https://example.com/x"

julia> tryparse(Uri, "/has space") === nothing
true
```
"""
struct Uri
    scheme::Scheme                  # tag 0x00 when absent
    authority::Authority            # empty when absent
    path_and_query::PathAndQuery
    global _u_uri(s::Scheme, a::Authority, pq::PathAndQuery) = new(s, a, pq)
end

const _U_DEFAULT = _u_uri(_U_SCHEME_NONE, _U_AUTHORITY_EMPTY, _U_PQ_SLASH)

"""
    UriParts(; scheme = nothing, authority = nothing, path_and_query = nothing)
    UriParts(u::Uri)

The components of a [`Uri`](@ref) as a mutable struct (the crate's
`uri::Parts`): take a URI apart, change a component, and build a new URI with
`Uri(parts)`.

# Fields
- `scheme::Union{Nothing,Scheme}`
- `authority::Union{Nothing,Authority}`
- `path_and_query::Union{Nothing,PathAndQuery}`

The keyword constructor and field assignment take already-parsed components
(`Scheme("https")`, `Schemes.HTTPS`, `Authority("example.com")`,
`PathAndQuery("/x")`), not strings. Use `Uri(; scheme = "https", ...)` to build
from strings.

`Uri(parts)` throws [`InvalidUriParts`](@ref) if the components do not combine.

# Examples
```jldoctest
julia> p = UriParts(uri"http://example.com/a?x=1");

julia> p.scheme = Schemes.HTTPS;

julia> p.path_and_query = PathAndQuery("/b");

julia> Uri(p)
uri"https://example.com/b"
```
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

Build a [`Uri`](@ref) from a request target that a parser has already split into
path bytes and query bytes, with a single `String` allocation. Not exported.

# Arguments
- `path_ptr::Ptr`, `path_len::Integer`: the path bytes.
- `query_ptr::Ptr`, `query_len::Integer`: the query bytes, without the `?`. Pass
  `query_len < 0` when the target had no `?` (`query_ptr` is then not read);
  `0` gives an empty query.

# Throws
- [`InvalidUri`](@ref), as `Uri(src)` does for the joined text.

# Examples
```jldoctest
julia> p, q = "/users", "page=2";

julia> GC.@preserve p q HttpTypes.uri_from_target(pointer(p), sizeof(p), pointer(q), sizeof(q))
uri"/users?page=2"

julia> GC.@preserve p HttpTypes.uri_from_target(pointer(p), sizeof(p), C_NULL, -1)
uri"/users"
```
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

A [`Uri`](@ref) literal, parsed and validated when the code is parsed: a
malformed literal is an error at macro expansion ([`InvalidUri`](@ref)), before
the program runs.

# Examples
```jldoctest
julia> uri"/static/app.js"
uri"/static/app.js"

julia> path(uri"https://example.com/a?b")
"/a"
```
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

"""
    path_and_query(u::Uri) -> Union{PathAndQuery,Nothing}

The [`PathAndQuery`](@ref) of a URI, or `nothing` for an authority-form URI
(`example.com:443`), which has none.

# Examples
```jldoctest
julia> path_and_query(uri"https://example.com/a?x=1")
PathAndQuery("/a?x=1")

julia> path_and_query(Uri("example.com:443")) === nothing
true
```
"""
path_and_query(u::Uri) =
    (u.scheme.tag != 0x00 || isempty(u.authority.data)) ? u.path_and_query : nothing
path(u::Uri) = _u_has_path(u) ? path(u.path_and_query) : _U_EMPTY
"""
    scheme(u::Uri) -> Union{Scheme,Nothing}

The [`Scheme`](@ref) of a URI, or `nothing` when it has none (origin-form and
authority-form URIs).

# Examples
```jldoctest
julia> scheme(uri"https://example.com/")
Schemes.HTTPS

julia> scheme(uri"/a") === nothing
true
```
"""
scheme(u::Uri) = u.scheme.tag == 0x00 ? nothing : u.scheme
"""
    scheme_str(u::Uri) -> Union{SubString{String},Nothing}

The scheme of a URI as text, as written, or `nothing` when it has none.

# Examples
```jldoctest
julia> scheme_str(uri"https://example.com/")
"https"

julia> scheme_str(uri"/a") === nothing
true
```
"""
scheme_str(u::Uri) = u.scheme.tag == 0x00 ? nothing : as_str(u.scheme)
"""
    authority(u::Uri) -> Union{Authority,Nothing}

The [`Authority`](@ref) of a URI (`[userinfo@]host[:port]`), or `nothing` when
it has none, as in an origin-form request target.

# Examples
```jldoctest
julia> authority(uri"https://example.com:8443/a")
Authority("example.com:8443")

julia> authority(uri"/a") === nothing
true
```
"""
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
