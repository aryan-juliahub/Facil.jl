export StatusCode, StatusCodes, InvalidStatusCode, canonical_reason,
    is_informational, is_success, is_redirection, is_client_error, is_server_error

"""
    InvalidStatusCode <: HttpError

Thrown by [`StatusCode`](@ref) (and by anything that converts to one, such as
`Response(; status = ...)`) for an integer outside `100:999`, or for text that
is not exactly three ASCII digits with a non-zero first digit. The message is
`invalid status code`.

# Examples
```jldoctest
julia> StatusCode(99)
ERROR: invalid status code
[...]

julia> tryparse(StatusCode, 1000) === nothing
true
```
"""
struct InvalidStatusCode <: HttpError end
Base.showerror(io::IO, ::InvalidStatusCode) = print(io, "invalid status code")

"""
    StatusCode(code::Integer)
    StatusCode(src)
    StatusCode(ptr::Ptr{UInt8}, len::Integer)
    StatusCode()
    tryparse(StatusCode, src)
    parse(StatusCode, src)

An HTTP status code in `100:999`.

Registered codes are constants in `StatusCodes` (`StatusCodes.OK`, ...). Codes
that are not registered are valid too, as long as they are in range.

# Arguments
- `code::Integer`: the numeric code.
- `src`: an `AbstractString` or `AbstractVector{UInt8}` of exactly three ASCII
  digits, or a `StatusCode` (returned as is).
- `ptr`, `len`: a pointer to `len` bytes holding the digits.

# Returns
A `StatusCode`. `StatusCode()` is `StatusCodes.OK`. `tryparse` accepts the same
sources (including an integer) and returns `nothing` instead of throwing.

# Throws
- [`InvalidStatusCode`](@ref) if the code is outside `100:999` or the text is not
  three digits.

# Notes
- `UInt16(s)` and `Int(s)` give the number; `s == 404` compares with an integer.
  Codes order (`isless`) by number.
- [`as_str`](@ref) gives the digits (`"404"`). `string(s)` and `print` give the
  digits and the reason phrase (`"404 Not Found"`), or
  `"299 <unknown status code>"` for an unregistered code.
- `show` prints `StatusCodes.NOT_FOUND`, or `StatusCode(299)` for an unregistered
  code.
- `convert(StatusCode, x)` accepts integers, strings and bytes, so
  `response.status = 404` works.

# Examples
```jldoctest
julia> StatusCode(404)
StatusCodes.NOT_FOUND

julia> StatusCode("201") === StatusCodes.CREATED
true

julia> s = StatusCode(299)
StatusCode(299)

julia> Int(s), string(s), canonical_reason(s)
(299, "299 <unknown status code>", nothing)

julia> StatusCodes.OK == 200, string(StatusCodes.OK)
(true, "200 OK")
```

See also [`canonical_reason`](@ref), [`is_success`](@ref),
[`is_client_error`](@ref), [`is_server_error`](@ref).
"""
struct StatusCode
    code::UInt16
    global _s_unchecked(code::UInt16) = new(code)
end

@noinline _s_throw() = throw(InvalidStatusCode())

@inline Base.tryparse(::Type{StatusCode}, code::Integer) =
    100 <= code <= 999 ? _s_unchecked(code % UInt16) : nothing
@inline function StatusCode(code::Integer)
    100 <= code <= 999 || _s_throw()
    return _s_unchecked(code % UInt16)
end
StatusCode(s::StatusCode) = s
StatusCode() = _s_unchecked(0x00c8)

@inline function _tryparse_status(p::Ptr{UInt8}, n::Int)::Union{StatusCode,Nothing}
    n == 3 || return nothing
    a = (unsafe_load(p, 1) - 0x30) % UInt16
    b = (unsafe_load(p, 2) - 0x30) % UInt16
    c = (unsafe_load(p, 3) - 0x30) % UInt16
    (a == 0 || a > 9 || b > 9 || c > 9) && return nothing
    return _s_unchecked(a * 0x0064 + b * 0x000a + c)
end
Base.tryparse(::Type{StatusCode}, p::Ptr{UInt8}, n::Integer) = _tryparse_status(p, Int(n))
@inline Base.tryparse(::Type{StatusCode}, src::BytesLike) =
    GC.@preserve src _tryparse_status(_ptr(src), _nbytes(src))
Base.tryparse(::Type{StatusCode}, src::AbstractString) = tryparse(StatusCode, String(src))
Base.tryparse(::Type{StatusCode}, src::AbstractVector{UInt8}) = tryparse(StatusCode, Vector{UInt8}(src))

@inline function StatusCode(src::Union{AbstractString,AbstractVector{UInt8}})
    s = tryparse(StatusCode, src)
    s === nothing && _s_throw()
    return s
end
@inline function StatusCode(p::Ptr{UInt8}, n::Integer)
    s = _tryparse_status(p, Int(n))
    s === nothing && _s_throw()
    return s
end
Base.parse(::Type{StatusCode}, src::AbstractString) = StatusCode(src)
Base.convert(::Type{StatusCode}, src::Union{Integer,AbstractString,AbstractVector{UInt8}}) = StatusCode(src)

const _S_TABLE = (
    (100, :CONTINUE, "Continue"), (101, :SWITCHING_PROTOCOLS, "Switching Protocols"),
    (102, :PROCESSING, "Processing"), (103, :EARLY_HINTS, "Early Hints"),
    (200, :OK, "OK"), (201, :CREATED, "Created"), (202, :ACCEPTED, "Accepted"),
    (203, :NON_AUTHORITATIVE_INFORMATION, "Non Authoritative Information"),
    (204, :NO_CONTENT, "No Content"), (205, :RESET_CONTENT, "Reset Content"),
    (206, :PARTIAL_CONTENT, "Partial Content"), (207, :MULTI_STATUS, "Multi-Status"),
    (208, :ALREADY_REPORTED, "Already Reported"), (226, :IM_USED, "IM Used"),
    (300, :MULTIPLE_CHOICES, "Multiple Choices"), (301, :MOVED_PERMANENTLY, "Moved Permanently"),
    (302, :FOUND, "Found"), (303, :SEE_OTHER, "See Other"), (304, :NOT_MODIFIED, "Not Modified"),
    (305, :USE_PROXY, "Use Proxy"), (307, :TEMPORARY_REDIRECT, "Temporary Redirect"),
    (308, :PERMANENT_REDIRECT, "Permanent Redirect"),
    (400, :BAD_REQUEST, "Bad Request"), (401, :UNAUTHORIZED, "Unauthorized"),
    (402, :PAYMENT_REQUIRED, "Payment Required"), (403, :FORBIDDEN, "Forbidden"),
    (404, :NOT_FOUND, "Not Found"), (405, :METHOD_NOT_ALLOWED, "Method Not Allowed"),
    (406, :NOT_ACCEPTABLE, "Not Acceptable"),
    (407, :PROXY_AUTHENTICATION_REQUIRED, "Proxy Authentication Required"),
    (408, :REQUEST_TIMEOUT, "Request Timeout"), (409, :CONFLICT, "Conflict"), (410, :GONE, "Gone"),
    (411, :LENGTH_REQUIRED, "Length Required"), (412, :PRECONDITION_FAILED, "Precondition Failed"),
    (413, :PAYLOAD_TOO_LARGE, "Payload Too Large"), (414, :URI_TOO_LONG, "URI Too Long"),
    (415, :UNSUPPORTED_MEDIA_TYPE, "Unsupported Media Type"),
    (416, :RANGE_NOT_SATISFIABLE, "Range Not Satisfiable"),
    (417, :EXPECTATION_FAILED, "Expectation Failed"), (418, :IM_A_TEAPOT, "I'm a teapot"),
    (421, :MISDIRECTED_REQUEST, "Misdirected Request"),
    (422, :UNPROCESSABLE_ENTITY, "Unprocessable Entity"), (423, :LOCKED, "Locked"),
    (424, :FAILED_DEPENDENCY, "Failed Dependency"), (425, :TOO_EARLY, "Too Early"),
    (426, :UPGRADE_REQUIRED, "Upgrade Required"),
    (428, :PRECONDITION_REQUIRED, "Precondition Required"),
    (429, :TOO_MANY_REQUESTS, "Too Many Requests"),
    (431, :REQUEST_HEADER_FIELDS_TOO_LARGE, "Request Header Fields Too Large"),
    (451, :UNAVAILABLE_FOR_LEGAL_REASONS, "Unavailable For Legal Reasons"),
    (500, :INTERNAL_SERVER_ERROR, "Internal Server Error"), (501, :NOT_IMPLEMENTED, "Not Implemented"),
    (502, :BAD_GATEWAY, "Bad Gateway"), (503, :SERVICE_UNAVAILABLE, "Service Unavailable"),
    (504, :GATEWAY_TIMEOUT, "Gateway Timeout"),
    (505, :HTTP_VERSION_NOT_SUPPORTED, "HTTP Version Not Supported"),
    (506, :VARIANT_ALSO_NEGOTIATES, "Variant Also Negotiates"),
    (507, :INSUFFICIENT_STORAGE, "Insufficient Storage"), (508, :LOOP_DETECTED, "Loop Detected"),
    (510, :NOT_EXTENDED, "Not Extended"),
    (511, :NETWORK_AUTHENTICATION_REQUIRED, "Network Authentication Required"),
)

"""
    StatusCodes

The registered status codes as [`StatusCode`](@ref HttpTypes.StatusCode) constants, named as in the
`http` crate: `StatusCodes.OK` (200), `StatusCodes.CREATED` (201),
`StatusCodes.NO_CONTENT` (204), `StatusCodes.MOVED_PERMANENTLY` (301),
`StatusCodes.FOUND` (302), `StatusCodes.NOT_MODIFIED` (304),
`StatusCodes.BAD_REQUEST` (400), `StatusCodes.UNAUTHORIZED` (401),
`StatusCodes.FORBIDDEN` (403), `StatusCodes.NOT_FOUND` (404),
`StatusCodes.METHOD_NOT_ALLOWED` (405), `StatusCodes.PAYLOAD_TOO_LARGE` (413),
`StatusCodes.UNPROCESSABLE_ENTITY` (422), `StatusCodes.TOO_MANY_REQUESTS` (429),
`StatusCodes.INTERNAL_SERVER_ERROR` (500), `StatusCodes.SERVICE_UNAVAILABLE`
(503) and the rest of the registry: 62 constants in all.

The constants are not exported one by one; write `StatusCodes.OK`. A code
without a constant is built with `StatusCode(n)`.

# Examples
```jldoctest
julia> StatusCodes.IM_A_TEAPOT
StatusCodes.IM_A_TEAPOT

julia> Int(StatusCodes.IM_A_TEAPOT), canonical_reason(StatusCodes.IM_A_TEAPOT)
(418, "I'm a teapot")
```
"""
baremodule StatusCodes end
for (n, k, _) in _S_TABLE
    Core.eval(StatusCodes, :(const $k = $(_s_unchecked(UInt16(n)))))
end

const _S_REASONS = let v = Vector{Union{Nothing,String}}(nothing, 900)
    for (n, _, phrase) in _S_TABLE
        v[n-99] = phrase
    end
    v
end
const _S_NAMES = let v = Vector{Union{Nothing,Symbol}}(nothing, 900)
    for (n, k, _) in _S_TABLE
        v[n-99] = k
    end
    v
end
const _S_DIGITS = [string(i) for i in 100:999]

"""
    canonical_reason(s::StatusCode) -> Union{String,Nothing}

The registered reason phrase of a status code, or `nothing` when the code is not
registered.

# Examples
```jldoctest
julia> canonical_reason(StatusCodes.NOT_FOUND)
"Not Found"

julia> canonical_reason(StatusCode(299)) === nothing
true
```
"""
canonical_reason(s::StatusCode) = @inbounds _S_REASONS[getfield(s, :code)-99]
as_str(s::StatusCode) = @inbounds _S_DIGITS[getfield(s, :code)-99]

"""
    is_informational(s::StatusCode) -> Bool

Whether the code is in `100:199`.

# Examples
```jldoctest
julia> is_informational(StatusCodes.CONTINUE), is_informational(StatusCodes.OK)
(true, false)
```
"""
is_informational(s::StatusCode) = 100 <= s.code < 200
"""
    is_success(s::StatusCode) -> Bool

Whether the code is in `200:299`.

# Examples
```jldoctest
julia> is_success(StatusCodes.CREATED), is_success(StatusCodes.NOT_FOUND)
(true, false)
```
"""
is_success(s::StatusCode) = 200 <= s.code < 300
"""
    is_redirection(s::StatusCode) -> Bool

Whether the code is in `300:399`.

# Examples
```jldoctest
julia> is_redirection(StatusCodes.FOUND), is_redirection(StatusCodes.OK)
(true, false)
```
"""
is_redirection(s::StatusCode) = 300 <= s.code < 400
"""
    is_client_error(s::StatusCode) -> Bool

Whether the code is in `400:499`.

# Examples
```jldoctest
julia> is_client_error(StatusCodes.NOT_FOUND), is_client_error(StatusCodes.BAD_GATEWAY)
(true, false)
```
"""
is_client_error(s::StatusCode) = 400 <= s.code < 500
"""
    is_server_error(s::StatusCode) -> Bool

Whether the code is in `500:599`. Codes in `600:999` are valid but belong to no
class: all five `is_*` functions return `false` for them.

# Examples
```jldoctest
julia> is_server_error(StatusCodes.BAD_GATEWAY), is_server_error(StatusCode(600))
(true, false)
```
"""
is_server_error(s::StatusCode) = 500 <= s.code < 600

Base.UInt16(s::StatusCode) = s.code
Base.Int(s::StatusCode) = Int(s.code)
Base.:(==)(a::StatusCode, b::Integer) = a.code == b
Base.:(==)(a::Integer, b::StatusCode) = a == b.code
Base.isless(a::StatusCode, b::StatusCode) = isless(a.code, b.code)
Base.hash(s::StatusCode, h::UInt) = hash(s.code, h)
function Base.show(io::IO, s::StatusCode)
    k = @inbounds _S_NAMES[s.code-99]
    k === nothing ? print(io, "StatusCode(", Int(s.code), ')') : print(io, "StatusCodes.", k)
end
function Base.print(io::IO, s::StatusCode)
    r = canonical_reason(s)
    print(io, Int(s.code), ' ', r === nothing ? "<unknown status code>" : r)
end
