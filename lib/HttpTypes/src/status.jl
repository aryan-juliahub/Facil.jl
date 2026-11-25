export StatusCode, StatusCodes, InvalidStatusCode, canonical_reason,
    is_informational, is_success, is_redirection, is_client_error, is_server_error

"""
    InvalidStatusCode

Thrown when a value is not a status code in `100:999`.
"""
struct InvalidStatusCode <: HttpError end
Base.showerror(io::IO, ::InvalidStatusCode) = print(io, "invalid status code")

"""
    StatusCode(code)
    tryparse(StatusCode, src)

An HTTP status code in `100:999`, from an integer or from exactly three ASCII digits
(string, bytes, or pointer and length). Registered codes are `StatusCodes.OK`, ...;
the default is `StatusCodes.OK`. `UInt16(s)` gives the number, `as_str(s)` the digits,
`string(s)` the digits and reason (`"404 Not Found"`).
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

"The registered status codes: `StatusCodes.OK`, `StatusCodes.NOT_FOUND`, ..."
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
    canonical_reason(s::StatusCode)

The registered reason phrase (`"Not Found"` for 404), or `nothing` for an unregistered code.
"""
canonical_reason(s::StatusCode) = @inbounds _S_REASONS[getfield(s, :code)-99]
as_str(s::StatusCode) = @inbounds _S_DIGITS[getfield(s, :code)-99]

"Whether the code is in `100:199`."
is_informational(s::StatusCode) = 100 <= s.code < 200
"Whether the code is in `200:299`."
is_success(s::StatusCode) = 200 <= s.code < 300
"Whether the code is in `300:399`."
is_redirection(s::StatusCode) = 300 <= s.code < 400
"Whether the code is in `400:499`."
is_client_error(s::StatusCode) = 400 <= s.code < 500
"Whether the code is in `500:599`."
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
