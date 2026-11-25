# Response bodies are sent without a copy. Each one stays here until facil.io's
# dealloc callback releases it; a body in several sends at once also has its
# send count in PIN_COUNT (absent means one).
const PINNED = Dict{UInt,Any}()
const PIN_COUNT = Dict{UInt,Int}()
const PIN_LOCK = Threads.SpinLock()
const BODY_DEALLOC = Ref{Ptr{Cvoid}}(C_NULL)

function pin!(obj, p::Ptr{UInt8})
    k = UInt(p)
    lock(PIN_LOCK)
    if haskey(PINNED, k)
        PIN_COUNT[k] = get(PIN_COUNT, k, 1) + 1
    else
        PINNED[k] = obj
    end
    unlock(PIN_LOCK)
    nothing
end

function body_released(p::Ptr{Cvoid})
    k = UInt(p)
    lock(PIN_LOCK)
    n = get(PIN_COUNT, k, 1)
    if n > 2
        PIN_COUNT[k] = n - 1
    elseif n == 2
        delete!(PIN_COUNT, k)
    else
        delete!(PINNED, k)
    end
    unlock(PIN_LOCK)
    nothing
end

"""
    Facil.pinned_bodies() -> Int

Number of response bodies still held for facil.io (sent, or being sent, without a copy).
"""
pinned_bodies() = (lock(PIN_LOCK); n = length(PINNED); unlock(PIN_LOCK); n)

const TEXT_PLAIN = "text/plain; charset=utf-8"
const OCTET_STREAM = "application/octet-stream"
const CT_ID = HttpTypes.standard_index(header.CONTENT_TYPE)
const CL_ID = HttpTypes.standard_index(header.CONTENT_LENGTH)
const TE_ID = HttpTypes.standard_index(header.TRANSFER_ENCODING)

@inline set_header(h::Ptr{Cvoid}, id::Integer, name::String, value::String) =
    GC.@preserve name value @ccall LIBFJL.fjl_resp_header(h::Ptr{Cvoid}, Int32(id)::Int32, pointer(name)::Ptr{UInt8}, sizeof(name)::Csize_t,
                                                          pointer(value)::Ptr{UInt8}, sizeof(value)::Csize_t)::Cint

# Writes every header except the framing ones facil.io owns; true when a
# content-type was among them.
function write_headers(h::Ptr{Cvoid}, hm::HeaderMap{HeaderValue})
    has_ct = false
    for (k, v) in hm
        id = HttpTypes.standard_index(k)
        (id == CL_ID || id == TE_ID) && continue
        has_ct |= id == CT_ID
        set_header(h, id, as_str(k), as_str(v))
    end
    has_ct
end

function send_body(h::Ptr{Cvoid}, status::Integer, body::Union{String,Vector{UInt8}})
    n = sizeof(body)
    GC.@preserve body begin
        p = Ptr{UInt8}(pointer(body))
        n > 0 && pin!(body, p)
        @ccall LIBFJL.fjl_resp_send(h::Ptr{Cvoid}, Cint(status)::Cint, p::Ptr{UInt8}, n::Csize_t, BODY_DEALLOC[]::Ptr{Cvoid})::Cint
    end
end

send_status(h::Ptr{Cvoid}, status::Integer) =
    @ccall LIBFJL.fjl_resp_send(h::Ptr{Cvoid}, Cint(status)::Cint, C_NULL::Ptr{UInt8}, 0::Csize_t, C_NULL::Ptr{Cvoid})::Cint

body_bytes(b::Union{String,Vector{UInt8},Nothing}) = b
body_bytes(b::AbstractString) = String(b)
body_bytes(b::AbstractVector{UInt8}) = Vector{UInt8}(b)
body_bytes(b) = throw(ArgumentError("unsupported response body type $(typeof(b)); use String, Vector{UInt8} or nothing"))

default_type(::String) = TEXT_PLAIN
default_type(::Vector{UInt8}) = OCTET_STREAM

"""
    respond(h, res)

Writes a handler's result. A `Response` is sent as is (a `content-type` is
added for a non-empty body that has none); a plain string is a 200 `text/plain`.
"""
@noinline function respond(h::Ptr{Cvoid}, res::Response)
    b = body_bytes(res.body)
    has_ct = write_headers(h, res.headers)
    status = Int(UInt16(res.status))
    if b === nothing || sizeof(b) == 0
        send_status(h, status)
    else
        has_ct || set_header(h, CT_ID, "content-type", default_type(b))
        send_body(h, status, b)
    end
    nothing
end

@noinline function respond(h::Ptr{Cvoid}, s::AbstractString)
    b = String(s)
    if sizeof(b) == 0
        send_status(h, 200)
    else
        set_header(h, CT_ID, "content-type", TEXT_PLAIN)
        send_body(h, 200, b)
    end
    nothing
end

respond(h::Ptr{Cvoid}, x) = throw(BadHandlerResult(typeof(x)))

struct BadHandlerResult <: Exception
    type::Type
end
Base.showerror(io::IO, e::BadHandlerResult) =
    print(io, "the handler returned a ", e.type, "; it must return a Response or a String")

# The first error of each type is logged; repeats within ERROR_LOG_INTERVAL are counted and summarised.
const ERROR_LOG_INTERVAL = 10.0
const ERROR_LOG = Dict{DataType,Tuple{Float64,Int}}()
const ERROR_LOG_LOCK = ReentrantLock()

function log_error(where::AbstractString, e, bt)
    t = typeof(e)
    now = time()
    suppressed = lock(ERROR_LOG_LOCK) do
        last, n = get(ERROR_LOG, t, (-Inf, 0))
        if now - last >= ERROR_LOG_INTERVAL
            ERROR_LOG[t] = (now, 0)
            n
        else
            ERROR_LOG[t] = (last, n + 1)
            -1
        end
    end
    suppressed < 0 && return nothing
    note = suppressed > 0 ? " ($suppressed more like it in the last $(Int(ERROR_LOG_INTERVAL)) s)" : ""
    callback_error(string(where, note), e, bt)
end
