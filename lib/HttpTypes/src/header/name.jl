export HeaderName, InvalidHeaderName, header, as_str, from_lowercase, from_static, @hn_str

"""
    InvalidHeaderName

Thrown when bytes are not a valid header field name (an RFC 9110 token of
1 to 65535 bytes).
"""
struct InvalidHeaderName <: HttpError end
Base.showerror(io::IO, ::InvalidHeaderName) = print(io, "invalid HTTP header name")

const MAX_HEADER_NAME_LEN = (1 << 16) - 1

"""
    HeaderName(src)
    tryparse(HeaderName, src)

A header field name, stored lowercase. `src` is a string, a byte vector, or a
pointer and length; uppercase is folded. Standard names are interned
(`header.CONTENT_TYPE`), so comparing two of them compares one integer.
"""
struct HeaderName
    id::UInt16
    name::String
    global _h_name_unchecked(id::UInt16, name::String) = new(id, name)
end

"""
The standard header names, in the order of their ids. `HttpTypes.standard_header(i)`
and `HttpTypes.standard_index(name)` convert between the two.
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

"Constants for the standard header names, e.g. `header.CONTENT_TYPE`."
baremodule header end
for (i, (k, s)) in enumerate(STANDARD_HEADER_TABLE)
    Core.eval(header, :(const $k = $(_h_name_unchecked(UInt16(i), s))))
end

const _H_STANDARD = [_h_name_unchecked(UInt16(i), s) for (i, (_, s)) in enumerate(STANDARD_HEADER_TABLE)]
const _H_MAX_STANDARD_LEN = maximum(t -> sizeof(t[2]), STANDARD_HEADER_TABLE)

"""
    HttpTypes.standard_header(i)

The standard `HeaderName` with id `i` (its position in `STANDARD_HEADER_TABLE`).
"""
@inline standard_header(i::Integer) = @inbounds _H_STANDARD[i]

"""
    HttpTypes.standard_index(name)

The id of a standard `HeaderName`, or 0 for a custom one.
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
    from_lowercase(HeaderName, src)

Like `HeaderName(src)` but rejects uppercase instead of folding it (the HTTP/2 rule).
"""
function from_lowercase(::Type{HeaderName}, src::BytesLike)
    h = GC.@preserve src _h_tryparse_name(_ptr(src), _nbytes(src), _H_CHARS_H2)
    h === nothing && throw(InvalidHeaderName())
    return h
end
from_lowercase(::Type{HeaderName}, src::Union{AbstractString,AbstractVector{UInt8}}) =
    from_lowercase(HeaderName, Vector{UInt8}(src))

"""
    from_static(HeaderName, s)

A `HeaderName` from a literal that must already be lowercase. Prefer `hn"..."`,
which checks it when the code is parsed.
"""
from_static(::Type{HeaderName}, src::String) = from_lowercase(HeaderName, src)

"`hn\"x-request-id\"` is a `HeaderName` validated when the code is parsed."
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
