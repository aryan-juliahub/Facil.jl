export HeaderName, InvalidHeaderName, header, as_str, from_lowercase, from_static, @hn_str

"""
    InvalidHeaderName <: HttpError

Thrown by [`HeaderName`](@ref), and by every [`HeaderMap`](@ref) function that
has to build a name from a string, when the source is not a valid header field
name: an RFC 9110 token of 1 to 65,535 bytes. The message is
`invalid HTTP header name`.

# Examples
```jldoctest
julia> HeaderName("bad name")
ERROR: invalid HTTP header name
[...]

julia> tryparse(HeaderName, "") === nothing
true
```
"""
struct InvalidHeaderName <: HttpError end
Base.showerror(io::IO, ::InvalidHeaderName) = print(io, "invalid HTTP header name")

const MAX_HEADER_NAME_LEN = (1 << 16) - 1

"""
    HeaderName(src)
    HeaderName(ptr::Ptr{UInt8}, len::Integer)
    tryparse(HeaderName, src)
    parse(HeaderName, src)

A header field name, stored in lowercase.

Header names are case-insensitive in HTTP; a `HeaderName` folds uppercase ASCII
letters when it is built, so two names that differ only in case are the same
value. The 81 standard names are constants in `header`
(`header.CONTENT_TYPE`, ...); parsing one of them returns that constant, and
comparing two standard names compares one integer.

# Arguments
- `src`: an `AbstractString` or `AbstractVector{UInt8}`, or a `HeaderName`
  (returned as is).
- `ptr`, `len`: a pointer to `len` bytes holding the name.

# Returns
A `HeaderName`. `tryparse` returns `nothing` instead of throwing.

# Throws
- [`InvalidHeaderName`](@ref) if the source is empty, longer than 65,535 bytes,
  or holds a byte that is not a token character (space, `:`, control bytes and
  non-ASCII bytes are all rejected).

# Notes
- `name == "Content-Type"` compares with a string, ignoring ASCII case.
- [`as_str`](@ref), `string(name)`, `String(name)` and `print` give the lowercase
  text; `show` prints the literal `hn"content-type"`.
- `hash(name)` differs from the hash of the equal string, so do not mix
  `HeaderName` and `String` keys in one `Dict`. A [`HeaderMap`](@ref) accepts
  both.
- For a literal name, [`hn"..."`](@ref @hn_str) validates when the code is
  parsed and costs nothing at run time.

# Examples
```jldoctest
julia> HeaderName("Content-Type")
hn"content-type"

julia> HeaderName("Content-Type") === header.CONTENT_TYPE
true

julia> name = HeaderName("X-Request-Id")
hn"x-request-id"

julia> name == "x-request-ID", string(name)
(true, "x-request-id")
```

See also [`from_lowercase`](@ref), [`from_static`](@ref).
"""
struct HeaderName
    id::UInt16
    name::String
    global _h_name_unchecked(id::UInt16, name::String) = new(id, name)
end

"""
    HttpTypes.STANDARD_HEADER_TABLE

The 81 standard header names as a tuple of `(constant::Symbol, name::String)`,
in the order of their ids: entry `i` is the constant `header.<constant>` and
its lowercase name. Not exported.

[`HttpTypes.standard_header`](@ref) and [`HttpTypes.standard_index`](@ref)
convert between a name and its id.

# Examples
```jldoctest
julia> HttpTypes.STANDARD_HEADER_TABLE[1]
(:ACCEPT, "accept")

julia> length(HttpTypes.STANDARD_HEADER_TABLE)
81
```
"""
const STANDARD_HEADER_TABLE = (
    (:ACCEPT, "accept"),
    (:ACCEPT_CHARSET, "accept-charset"),
    (:ACCEPT_ENCODING, "accept-encoding"),
    (:ACCEPT_LANGUAGE, "accept-language"),
    (:ACCEPT_RANGES, "accept-ranges"),
    (:ACCESS_CONTROL_ALLOW_CREDENTIALS, "access-control-allow-credentials"),
    (:ACCESS_CONTROL_ALLOW_HEADERS, "access-control-allow-headers"),
    (:ACCESS_CONTROL_ALLOW_METHODS, "access-control-allow-methods"),
    (:ACCESS_CONTROL_ALLOW_ORIGIN, "access-control-allow-origin"),
    (:ACCESS_CONTROL_EXPOSE_HEADERS, "access-control-expose-headers"),
    (:ACCESS_CONTROL_MAX_AGE, "access-control-max-age"),
    (:ACCESS_CONTROL_REQUEST_HEADERS, "access-control-request-headers"),
    (:ACCESS_CONTROL_REQUEST_METHOD, "access-control-request-method"),
    (:AGE, "age"),
    (:ALLOW, "allow"),
    (:ALT_SVC, "alt-svc"),
    (:AUTHORIZATION, "authorization"),
    (:CACHE_CONTROL, "cache-control"),
    (:CACHE_STATUS, "cache-status"),
    (:CDN_CACHE_CONTROL, "cdn-cache-control"),
    (:CONNECTION, "connection"),
    (:CONTENT_DISPOSITION, "content-disposition"),
    (:CONTENT_ENCODING, "content-encoding"),
    (:CONTENT_LANGUAGE, "content-language"),
    (:CONTENT_LENGTH, "content-length"),
    (:CONTENT_LOCATION, "content-location"),
    (:CONTENT_RANGE, "content-range"),
    (:CONTENT_SECURITY_POLICY, "content-security-policy"),
    (:CONTENT_SECURITY_POLICY_REPORT_ONLY, "content-security-policy-report-only"),
    (:CONTENT_TYPE, "content-type"),
    (:COOKIE, "cookie"),
    (:DNT, "dnt"),
    (:DATE, "date"),
    (:ETAG, "etag"),
    (:EXPECT, "expect"),
    (:EXPIRES, "expires"),
    (:FORWARDED, "forwarded"),
    (:FROM, "from"),
    (:HOST, "host"),
    (:IF_MATCH, "if-match"),
    (:IF_MODIFIED_SINCE, "if-modified-since"),
    (:IF_NONE_MATCH, "if-none-match"),
    (:IF_RANGE, "if-range"),
    (:IF_UNMODIFIED_SINCE, "if-unmodified-since"),
    (:LAST_MODIFIED, "last-modified"),
    (:LINK, "link"),
    (:LOCATION, "location"),
    (:MAX_FORWARDS, "max-forwards"),
    (:ORIGIN, "origin"),
    (:PRAGMA, "pragma"),
    (:PROXY_AUTHENTICATE, "proxy-authenticate"),
    (:PROXY_AUTHORIZATION, "proxy-authorization"),
    (:PUBLIC_KEY_PINS, "public-key-pins"),
    (:PUBLIC_KEY_PINS_REPORT_ONLY, "public-key-pins-report-only"),
    (:RANGE, "range"),
    (:REFERER, "referer"),
    (:REFERRER_POLICY, "referrer-policy"),
    (:REFRESH, "refresh"),
    (:RETRY_AFTER, "retry-after"),
    (:SEC_WEBSOCKET_ACCEPT, "sec-websocket-accept"),
    (:SEC_WEBSOCKET_EXTENSIONS, "sec-websocket-extensions"),
    (:SEC_WEBSOCKET_KEY, "sec-websocket-key"),
    (:SEC_WEBSOCKET_PROTOCOL, "sec-websocket-protocol"),
    (:SEC_WEBSOCKET_VERSION, "sec-websocket-version"),
    (:SERVER, "server"),
    (:SET_COOKIE, "set-cookie"),
    (:STRICT_TRANSPORT_SECURITY, "strict-transport-security"),
    (:TE, "te"),
    (:TRAILER, "trailer"),
    (:TRANSFER_ENCODING, "transfer-encoding"),
    (:USER_AGENT, "user-agent"),
    (:UPGRADE, "upgrade"),
    (:UPGRADE_INSECURE_REQUESTS, "upgrade-insecure-requests"),
    (:VARY, "vary"),
    (:VIA, "via"),
    (:WARNING, "warning"),
    (:WWW_AUTHENTICATE, "www-authenticate"),
    (:X_CONTENT_TYPE_OPTIONS, "x-content-type-options"),
    (:X_DNS_PREFETCH_CONTROL, "x-dns-prefetch-control"),
    (:X_FRAME_OPTIONS, "x-frame-options"),
    (:X_XSS_PROTECTION, "x-xss-protection"),
)

"""
    header

The standard header names as [`HeaderName`](@ref HttpTypes.HeaderName) constants, named as in the
`http` crate: `header.ACCEPT`, `header.AUTHORIZATION`, `header.CACHE_CONTROL`,
`header.CONTENT_LENGTH`, `header.CONTENT_TYPE`, `header.COOKIE`, `header.HOST`,
`header.LOCATION`, `header.SET_COOKIE`, `header.USER_AGENT` and so on, 81 in
all ([`HttpTypes.STANDARD_HEADER_TABLE`](@ref) lists them).

The constant for a name is its uppercase form with `-` replaced by `_`. The
constants are not exported one by one; write `header.CONTENT_TYPE`. Names
without a constant are written `hn"x-request-id"`.

# Examples
```jldoctest
julia> header.CONTENT_TYPE
hn"content-type"

julia> header.CONTENT_TYPE == "Content-Type"
true
```
"""
baremodule header end
for (i, (k, s)) in enumerate(STANDARD_HEADER_TABLE)
    Core.eval(header, :(const $k = $(_h_name_unchecked(UInt16(i), s))))
end

const _H_STANDARD = [_h_name_unchecked(UInt16(i), s) for (i, (_, s)) in enumerate(STANDARD_HEADER_TABLE)]
const _H_MAX_STANDARD_LEN = maximum(t -> sizeof(t[2]), STANDARD_HEADER_TABLE)

"""
    HttpTypes.standard_header(i::Integer) -> HeaderName

The standard [`HeaderName`](@ref) with id `i`, its position in
[`HttpTypes.STANDARD_HEADER_TABLE`](@ref). Not exported.

`i` must be in `1:81`; it is not checked (an out-of-range id is undefined
behaviour). Meant for parsers that have already matched a standard name.

# Examples
```jldoctest
julia> HttpTypes.standard_header(1)
hn"accept"
```
"""
@inline standard_header(i::Integer) = @inbounds _H_STANDARD[i]

"""
    HttpTypes.standard_index(name::HeaderName) -> Int

The id of a standard [`HeaderName`](@ref) (its position in
[`HttpTypes.STANDARD_HEADER_TABLE`](@ref)), or `0` for any other name.
Not exported.

# Examples
```jldoctest
julia> HttpTypes.standard_index(header.ACCEPT)
1

julia> HttpTypes.standard_index(hn"x-request-id")
0
```
"""
@inline standard_index(h::HeaderName) = Int(getfield(h, :id))

# Lowercasing token tables: valid bytes map to their lowercase form, others to 0.
const _H_CHARS = let t = zeros(UInt8, 256)
    for c in "!#\$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyz"
        t[UInt8(c)+1] = UInt8(c)
    end
    for c in 'A':'Z'
        t[UInt8(c)+1] = UInt8(c) + 0x20
    end
    t
end
const _H_CHARS_H2 = let t = copy(_H_CHARS)
    for c in 'A':'Z'
        t[UInt8(c)+1] = 0x00
    end
    t
end

const _H_STD_SLOTS = 512

# Samples a few bytes instead of the whole name; collisions are settled by probing.
@inline function _h_std_hash(p::Ptr{UInt8}, n::Int, table::Vector{UInt8})
    @inbounds begin
        a = table[_load(p, 1)+1] % UInt32
        z = table[_load(p, n)+1] % UInt32
        m = table[_load(p, (n >> 1) + 1)+1] % UInt32
        k = n > 6 ? table[_load(p, n - 6)+1] % UInt32 : 0x00000000
    end
    h = ((n % UInt32) + (a << 8) + (z << 16) + (m << 24)) ⊻ (k * 0x00009e37)
    return ((h * 0x9e3779b1) >> 23) % Int
end

const _H_STD_INDEX = let slots = zeros(UInt8, _H_STD_SLOTS)
    for (i, (_, s)) in enumerate(STANDARD_HEADER_TABLE)
        h = GC.@preserve s _h_std_hash(pointer(s), sizeof(s), _H_CHARS)
        while slots[h+1] != 0
            h = (h + 1) & (_H_STD_SLOTS - 1)
        end
        slots[h+1] = i
    end
    slots
end

@inline function _h_lc_eq(p::Ptr{UInt8}, n::Int, lower::String, table::Vector{UInt8})
    q = pointer(lower)
    ok = true
    for i in 1:n
        ok &= @inbounds(table[_load(p, i)+1]) == _load(q, i)
    end
    return ok
end

# Id of the standard header spelled by these bytes (any case under `table`), or 0.
@inline function _h_std_lookup(p::Ptr{UInt8}, n::Int, table::Vector{UInt8})::UInt16
    (n == 0 || n > _H_MAX_STANDARD_LEN) && return 0x0000
    h = _h_std_hash(p, n, table)
    while true
        id = @inbounds _H_STD_INDEX[h+1]
        id == 0x00 && return 0x0000
        s = getfield(@inbounds(_H_STANDARD[id]), :name)
        sizeof(s) == n && _h_lc_eq(p, n, s, table) && return id % UInt16
        h = (h + 1) & (_H_STD_SLOTS - 1)
    end
end

function _h_custom_name(p::Ptr{UInt8}, n::Int, table::Vector{UInt8})::Union{HeaderName,Nothing}
    s = Base._string_n(n)
    bad = false
    GC.@preserve s begin
        q = pointer(s)
        for i in 1:n
            b = @inbounds table[_load(p, i)+1]
            bad |= b == 0x00
            unsafe_store!(q, b, i)
        end
    end
    bad && return nothing
    return _h_name_unchecked(0x0000, s)
end

@inline function _h_tryparse_name(p::Ptr{UInt8}, n::Int, table::Vector{UInt8})::Union{HeaderName,Nothing}
    (n == 0 || n > MAX_HEADER_NAME_LEN) && return nothing
    id = _h_std_lookup(p, n, table)
    id != 0x0000 && return @inbounds _H_STANDARD[id]
    return _h_custom_name(p, n, table)
end

Base.tryparse(::Type{HeaderName}, p::Ptr{UInt8}, n::Integer) = _h_tryparse_name(p, Int(n), _H_CHARS)
@inline Base.tryparse(::Type{HeaderName}, src::BytesLike) =
    GC.@preserve src _h_tryparse_name(_ptr(src), _nbytes(src), _H_CHARS)
Base.tryparse(::Type{HeaderName}, src::AbstractString) = tryparse(HeaderName, String(src))
Base.tryparse(::Type{HeaderName}, src::AbstractVector{UInt8}) = tryparse(HeaderName, Vector{UInt8}(src))

@inline function HeaderName(src::Union{AbstractString,AbstractVector{UInt8}})
    h = tryparse(HeaderName, src)
    h === nothing && throw(InvalidHeaderName())
    return h
end
@inline function HeaderName(p::Ptr{UInt8}, n::Integer)
    h = _h_tryparse_name(p, Int(n), _H_CHARS)
    h === nothing && throw(InvalidHeaderName())
    return h
end
HeaderName(h::HeaderName) = h
Base.parse(::Type{HeaderName}, src::Union{AbstractString,AbstractVector{UInt8}}) = HeaderName(src)
Base.convert(::Type{HeaderName}, src::Union{AbstractString,AbstractVector{UInt8}}) = HeaderName(src)

"""
    from_lowercase(HeaderName, src) -> HeaderName

Like `HeaderName(src)`, but an uppercase letter is an error instead of being
folded. This is the rule for HTTP/2 and HTTP/3 field names.

# Arguments
- `src`: an `AbstractString` or `AbstractVector{UInt8}`.

# Throws
- [`InvalidHeaderName`](@ref) if `src` is not a valid name or holds an uppercase
  ASCII letter.

# Examples
```jldoctest
julia> from_lowercase(HeaderName, "x-request-id")
hn"x-request-id"

julia> from_lowercase(HeaderName, "X-Request-Id")
ERROR: invalid HTTP header name
[...]
```
"""
function from_lowercase(::Type{HeaderName}, src::BytesLike)
    h = GC.@preserve src _h_tryparse_name(_ptr(src), _nbytes(src), _H_CHARS_H2)
    h === nothing && throw(InvalidHeaderName())
    return h
end
from_lowercase(::Type{HeaderName}, src::Union{AbstractString,AbstractVector{UInt8}}) =
    from_lowercase(HeaderName, Vector{UInt8}(src))

"""
    from_static(HeaderName, s::String) -> HeaderName
    from_static(HeaderValue, s::String) -> HeaderValue

A [`HeaderName`](@ref) or [`HeaderValue`](@ref) from a string literal (the
crate's `from_static`).

Prefer the string macros [`hn"..."`](@ref @hn_str) and
[`hv"..."`](@ref @hv_str): they do the same check once, when the code is parsed.

# Arguments
- `s::String`: for a `HeaderName`, a valid name that is already lowercase; for a
  `HeaderValue`, visible ASCII (tabs allowed).

# Throws
- [`InvalidHeaderName`](@ref) for an invalid name or one with an uppercase letter.
- [`InvalidHeaderValue`](@ref) for an invalid value.

# Examples
```jldoctest
julia> from_static(HeaderName, "x-request-id")
hn"x-request-id"

julia> from_static(HeaderValue, "text/plain")
hv"text/plain"
```
"""
from_static(::Type{HeaderName}, src::String) = from_lowercase(HeaderName, src)

"""
    hn"name"

A [`HeaderName`](@ref) literal, checked when the code is parsed.

The text must be a valid header name written in lowercase; anything else is an
error at macro expansion ([`InvalidHeaderName`](@ref)), before the program runs.
A standard name gives the same value as its `header` constant.

# Examples
```jldoctest
julia> hn"x-request-id"
hn"x-request-id"

julia> hn"content-type" === header.CONTENT_TYPE
true
```
"""
macro hn_str(s)
    return from_static(HeaderName, s)
end

"""
    as_str(name::HeaderName)

The name as a lowercase `String`.
"""
as_str(h::HeaderName) = getfield(h, :name)
Base.String(h::HeaderName) = as_str(h)
Base.string(h::HeaderName) = as_str(h)
Base.codeunits(h::HeaderName) = codeunits(as_str(h))
Base.sizeof(h::HeaderName) = sizeof(as_str(h))
Base.print(io::IO, h::HeaderName) = print(io, as_str(h))
Base.show(io::IO, h::HeaderName) = print(io, "hn\"", as_str(h), '"')

@inline function Base.:(==)(a::HeaderName, b::HeaderName)
    ia = getfield(a, :id)
    return ia == getfield(b, :id) && (ia != 0x0000 || as_str(a) == as_str(b))
end
function Base.:(==)(a::HeaderName, b::StrLike)
    s = as_str(a)
    n = sizeof(b)
    n == sizeof(s) || return false
    return GC.@preserve b s _h_lc_eq(_ptr(b), n, s, _H_CHARS)
end
Base.:(==)(a::StrLike, b::HeaderName) = b == a
Base.hash(h::HeaderName, x::UInt) = hash(as_str(h), hash(:HeaderName, x))
Base.isless(a::HeaderName, b::HeaderName) = isless(as_str(a), as_str(b))
