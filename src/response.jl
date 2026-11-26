# Response bodies are sent without a copy. Each one stays here until facil.io's
# dealloc callback releases it; a body in several sends at once also has its
# send count in PIN_COUNT (absent means one).
const PINNED = Dict{UInt,Any}()
const PIN_COUNT = Dict{UInt,Int}()
const PIN_LOCK = Threads.SpinLock()
const BODY_DEALLOC = Ref{Ptr{Cvoid}}(C_NULL)

@static if VERSION >= v"1.11-"
    # The bytes facil.io reads belong to the vector's Memory: resizing a queued
    # vector moves it to new Memory, and the old one stays pinned here.
    pin_target(b::Vector{UInt8}, ::UInt) = getfield(b, :ref).mem
    unshare!(::Vector{UInt8}, ::UInt) = nothing
else
    # A Julia 1.10 vector reallocates its buffer in place, so a queued vector is
    # marked shared: resizing it throws instead of freeing what C still reads.
    const SHARED_BIT = UInt16(1) << 14
    const MARKED = Set{UInt}()
    flags_ptr(b::Vector{UInt8}) = Ptr{UInt16}(pointer_from_objref(b)) + 2 * sizeof(Ptr{Cvoid})
    function pin_target(b::Vector{UInt8}, k::UInt)
        f = flags_ptr(b)
        x = unsafe_load(f)
        if x & 0x3 != 0x3 && x & SHARED_BIT == 0
            unsafe_store!(f, x | SHARED_BIT)
            push!(MARKED, k)
        end
        b
    end
    function unshare!(b::Vector{UInt8}, k::UInt)
        k in MARKED || return nothing
        delete!(MARKED, k)
        f = flags_ptr(b)
        unsafe_store!(f, unsafe_load(f) & ~SHARED_BIT)
        nothing
    end
end
pin_target(b::String, ::UInt) = b

function pin!(obj::Union{String,Vector{UInt8}}, p::Ptr{UInt8})
    k = UInt(p)
    lock_sigatomic(PIN_LOCK)
    if haskey(PINNED, k)
        PIN_COUNT[k] = get(PIN_COUNT, k, 1) + 1
    else
        PINNED[k] = pin_target(obj, k)
    end
    unlock_sigatomic(PIN_LOCK)
    nothing
end

function body_released(p::Ptr{Cvoid})
    k = UInt(p)
    lock_sigatomic(PIN_LOCK)
    n = get(PIN_COUNT, k, 1)
    if n > 2
        PIN_COUNT[k] = n - 1
    elseif n == 2
        delete!(PIN_COUNT, k)
    else
        v = pop!(PINNED, k, nothing)
        v isa Vector{UInt8} && unshare!(v, k)
    end
    unlock_sigatomic(PIN_LOCK)
    nothing
end

"""
    Facil.pinned_bodies() -> Int

The number of response bodies Facil is holding for facil.io because they are
being sent without a copy. It returns to `0` when every response has been
written to its socket; a value that keeps growing means clients are not reading.
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

# Statuses that never carry content: a body given with one is not sent.
bodyless(status::Integer) = status < 200 || status == 204 || status == 304

"""
    respond(h, res)

Writes a handler's result. A `Response` is sent as is (a `content-type` is
added for a non-empty body that has none); a plain string is a 200 `text/plain`.
"""
@noinline function respond(h::Ptr{Cvoid}, res::Response)
    b = body_bytes(res.body)
    has_ct = write_headers(h, res.headers)
    status = Int(UInt16(res.status))
    if b === nothing || sizeof(b) == 0 || bodyless(status)
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

# The first error of each type from each call site is logged; repeats within
# ERROR_LOG_INTERVAL are counted and summarised.
const ERROR_LOG_INTERVAL = 10.0
const ERROR_LOG_FRAMES = 4
const ERROR_LOG_MAX = 1024
const ERROR_LOG = Dict{UInt,Tuple{Float64,Int}}()
const ERROR_LOG_LOCK = ReentrantLock()

# The error's type and the innermost frames of its backtrace.
function log_error_key(e, bt)
    h = hash(typeof(e))
    bt isa AbstractVector || return h
    for i in 1:min(ERROR_LOG_FRAMES, length(bt))
        h = hash(bt[i], h)
    end
    h
end

log_error_reset!() = (locked(() -> empty!(ERROR_LOG), ERROR_LOG_LOCK); nothing)

function log_error(where::AbstractString, e, bt)
    t = log_error_key(e, bt)
    now = time()
    suppressed = locked(ERROR_LOG_LOCK) do
        length(ERROR_LOG) >= ERROR_LOG_MAX && !haskey(ERROR_LOG, t) && empty!(ERROR_LOG)
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
