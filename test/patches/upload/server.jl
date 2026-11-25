# Usage: julia -t 2 server.jl <port> <lib.dylib> [key=value ...]
#   body=v10|stock   v10: the http1_body_* path; stock: fiobj_data through the shim (any library)
#   alloc=c|jl       v10 buffered bodies: C malloc + unsafe_wrap(own=true), or a Julia vector rooted in ROOTS
#   threads=1        reactor threads
#   async=0|1        run buffered handlers on a Julia task (pause/resume)
#   memlimit=N maxbody=N timeout=N chunk=N gcloop=0|1
# Routes: /<op>[/<mode>]
#   op:   upload (length + cheap checksum), sha (length + sha256), reject (401 before the body), mv (spool, rename, delete)
#   mode: "" default plan, b memory (owned by Julia), v memory borrowed from C until the response is sent,
#         f temp file, s streamed to an inline callback, t streamed to a task
using SHA

const PORT = ARGS[1]
const LIB = ARGS[2]
const OPT = Dict{String,String}(split(a, '=')[1] => split(a, '=')[2] for a in ARGS[3:end])
opt(k, d) = parse(Int, get(OPT, k, string(d)))
const V10 = get(OPT, "body", "v10") == "v10"
const ALLOC_JL = get(OPT, "alloc", "c") == "jl"
const ASYNC = opt("async", 0) == 1
const MEMLIMIT = opt("memlimit", 8 << 20)
const HIGH_WATER = opt("highwater", 4 << 20)

struct HttpSettings
    on_request::Ptr{Cvoid}
    on_upgrade::Ptr{Cvoid}
    on_response::Ptr{Cvoid}
    on_finish::Ptr{Cvoid}
    udata::Ptr{Cvoid}
    public_folder::Ptr{Cchar}
    public_folder_length::Csize_t
    max_header_size::Csize_t
    max_body_size::Csize_t
    max_clients::Int
    tls::Ptr{Cvoid}
    reserved1::Int
    reserved2::Int
    reserved3::Int
    ws_max_msg_size::Csize_t
    timeout::UInt8
    ws_timeout::UInt8
    log::UInt8
    is_client::UInt8
end
struct Slice
    ptr::Ptr{UInt8}
    len::Csize_t
end
struct CReq
    method_code::Int32
    nheaders::Int32
    method::Slice
    path::Slice
    query::Slice
    version::Slice
    body::Slice
end
struct BodyConfig
    on_headers::Ptr{Cvoid}
    on_data::Ptr{Cvoid}
    on_abort::Ptr{Cvoid}
    mem_limit::Csize_t
    read_chunk::Csize_t
end
struct BodyPlan
    mode::Int32
    status::Int32
    dest::Ptr{UInt8}
    udata::UInt
    mem_limit::Csize_t
end
struct BodyInfo
    mode::Int32
    fd::Int32
    data::Ptr{UInt8}
    len::Csize_t
    udata::UInt
    path::Cstring
end
const B_VIEW, B_MALLOC, B_EXTERN, B_STREAM, B_FILE = Int32(1), Int32(2), Int32(3), Int32(4), Int32(5)

@inline str(s::Slice) = unsafe_string(s.ptr, s.len)

function req_path(h::Ptr{Cvoid})
    r = Ref{CReq}()
    ccall((:jlshim_req_head, LIB), Cint, (Ptr{Cvoid}, Ref{CReq}), h, r)
    return str(r[].path)
end

function respond(h::Ptr{Cvoid}, status::Int, body::String, ctype::String = "text/plain")
    name = "content-type"
    GC.@preserve name ctype body begin
        n = Ref(Slice(pointer(name), sizeof(name)))
        v = Ref(Slice(pointer(ctype), sizeof(ctype)))
        ccall((:jlshim_respond, LIB), Cint,
              (Ptr{Cvoid}, Cint, Ref{Slice}, Ref{Slice}, Cint, Ptr{UInt8}, Csize_t),
              h, status, n, v, 1, body, sizeof(body))
    end
    return nothing
end

const SMALL_JSON = """{"id":1,"name":"alice","email":"alice@example.com","tags":["admin","reviewer"],"created_at":"2024-01-01T12:00:00Z","status":"active","login_count":42}"""

# Length plus the sum of every 1024th byte and the last byte.
function checksum(p::Ptr{UInt8}, n::Int, offset::Int = 0)
    s = 0
    i = (1024 - offset % 1024) % 1024
    while i < n
        s += unsafe_load(p, i + 1)
        i += 1024
    end
    return s
end
function summary(op::Int, b::Vector{UInt8})
    n = length(b)
    op == 2 && return string(n, " ", bytes2hex(sha256(b)))
    s = GC.@preserve b checksum(pointer(b), n)
    n > 0 && (s += b[n])
    return string(n, " ", s)
end

# ---- state shared with the reactor threads

const state_lock = Threads.SpinLock()
const next_id = Threads.Atomic{UInt}(1)
new_id() = Threads.atomic_add!(next_id, UInt(1))
# Bodies being received into Julia-owned memory, by request id.
const ROOTS = Dict{UInt,Vector{UInt8}}()

mutable struct StreamState
    op::Int
    n::Int
    sum::Int
    last::UInt8
    ctx::Union{Nothing,SHA.SHA2_256_CTX}
    ch::Union{Nothing,Channel{Vector{UInt8}}}
    queued::Threads.Atomic{Int}
    paused::Threads.Atomic{Bool}
    uuid::Int
    task::Union{Nothing,Task}
    peak::Int
end
const STREAMS = Dict{UInt,StreamState}()
const ABORTS = Threads.Atomic{Int}(0)
const PAUSES = Threads.Atomic{Int}(0)
const PEAK_QUEUED = Threads.Atomic{Int}(0)

function feed!(st::StreamState, p::Ptr{UInt8}, len::Int)
    if st.op == 2
        SHA.update!(st.ctx, unsafe_wrap(Array, p, len))
    else
        st.sum += checksum(p, len, st.n)
    end
    len > 0 && (st.last = unsafe_load(p, len))
    st.n += len
    return nothing
end
function result(st::StreamState)
    st.op == 2 && return string(st.n, " ", bytes2hex(SHA.digest!(st.ctx)))
    return string(st.n, " ", st.sum + (st.n > 0 ? Int(st.last) : 0))
end

# The task side of a streamed body: chunks arrive on a channel; reading resumes
# once the backlog is drained.
function consume(st::StreamState)
    for chunk in st.ch
        GC.@preserve chunk feed!(st, pointer(chunk), length(chunk))
        q = Threads.atomic_sub!(st.queued, length(chunk)) - length(chunk)
        if q <= 0 && Threads.atomic_cas!(st.paused, true, false)
            ccall((:http1_body_resume, LIB), Cvoid, (Int,), st.uuid)
            ccall((:shim_wake, LIB), Cvoid, ())
        end
    end
    return result(st)
end

function parse_route(path::String)
    op = startswith(path, "/upload") ? 1 : startswith(path, "/sha") ? 2 :
         startswith(path, "/reject") ? 3 : startswith(path, "/mv") ? 4 : 0
    i = findnext('/', path, 2)
    mode = i === nothing ? ' ' : path[i + 1]
    return op, mode
end

function headers_cb(h::Ptr{Cvoid}, clen::Int64, planp::Ptr{BodyPlan})::Cvoid
    op, mode = parse_route(req_path(h))
    plan = unsafe_load(planp)
    if op == 3 || op == 0
        unsafe_store!(planp, BodyPlan(plan.mode, op == 3 ? 401 : 404, C_NULL, 0, plan.mem_limit))
    elseif mode == 'f' || op == 4
        unsafe_store!(planp, BodyPlan(B_FILE, 0, C_NULL, 0, plan.mem_limit))
    elseif mode == 's' || mode == 't'
        id = new_id()
        st = StreamState(op, 0, 0, 0x00, op == 2 ? SHA.SHA2_256_CTX() : nothing, nothing,
                         Threads.Atomic{Int}(0), Threads.Atomic{Bool}(false),
                         ccall((:http1_body_uuid, LIB), Int, (Ptr{Cvoid},), h), nothing, 0)
        if mode == 't'
            st.ch = Channel{Vector{UInt8}}(Inf)
            st.task = Threads.@spawn consume($st)
        end
        lock(state_lock); STREAMS[id] = st; unlock(state_lock)
        unsafe_store!(planp, BodyPlan(B_STREAM, 0, C_NULL, id, plan.mem_limit))
    elseif mode == 'v'
        unsafe_store!(planp, BodyPlan(B_MALLOC, 0, C_NULL, 0, typemax(Csize_t)))
    elseif ALLOC_JL && clen >= 0 && (mode == 'b' || clen <= MEMLIMIT)
        id = new_id()
        v = Vector{UInt8}(undef, clen)
        lock(state_lock); ROOTS[id] = v; unlock(state_lock)
        unsafe_store!(planp, BodyPlan(B_EXTERN, 0, pointer(v), id, plan.mem_limit))
    elseif mode == 'b'
        unsafe_store!(planp, BodyPlan(B_MALLOC, 0, C_NULL, 0, typemax(Csize_t)))
    end
    return nothing
end

function data_cb(h::Ptr{Cvoid}, id::UInt, p::Ptr{UInt8}, len::Csize_t)::Cint
    lock(state_lock); st = STREAMS[id]; unlock(state_lock)
    if st.ch === nothing
        feed!(st, p, Int(len))
        return 0
    end
    chunk = Vector{UInt8}(undef, len)
    unsafe_copyto!(pointer(chunk), p, len)
    q = Threads.atomic_add!(st.queued, Int(len)) + Int(len)
    q > PEAK_QUEUED[] && (PEAK_QUEUED[] = q)
    pause = q > HIGH_WATER
    pause && (st.paused[] = true; Threads.atomic_add!(PAUSES, 1))
    put!(st.ch, chunk)
    return pause ? 1 : 0
end

function abort_cb(id::UInt, mode::Int32)::Cvoid
    Threads.atomic_add!(ABORTS, 1)
    lock(state_lock)
    st = mode == B_STREAM ? pop!(STREAMS, id, nothing) : (pop!(ROOTS, id, nothing); nothing)
    unlock(state_lock)
    st !== nothing && st.ch !== nothing && close(st.ch, ErrorException("connection lost"))
    return nothing
end

function body_info(h::Ptr{Cvoid})
    info = Ref{BodyInfo}()
    ccall((:http1_body_info, LIB), Cint, (Ptr{Cvoid}, Ref{BodyInfo}), h, info)
    return info[]
end

# The whole body as a vector that Julia owns.
function read_body(h::Ptr{Cvoid}, info::BodyInfo)
    if info.mode == B_VIEW
        out = Vector{UInt8}(undef, info.len)
        unsafe_copyto!(pointer(out), info.data, info.len)
        return out
    elseif info.mode == B_MALLOC
        p = ccall((:http1_body_take, LIB), Ptr{UInt8}, (Ptr{Cvoid},), h)
        p == C_NULL && return UInt8[]
        return unsafe_wrap(Array, p, Int(info.len); own = true)
    elseif info.mode == B_EXTERN
        lock(state_lock); v = pop!(ROOTS, info.udata); unlock(state_lock)
        return v
    elseif info.mode == B_FILE
        return read(unsafe_string(info.path))
    end
    return UInt8[]
end

function read_body_stock(h::Ptr{Cvoid})
    s = ccall((:jlshim_req_body, LIB), Slice, (Ptr{Cvoid},), h)
    out = Vector{UInt8}(undef, s.len)
    s.len > 0 && unsafe_copyto!(pointer(out), s.ptr, s.len)
    return out
end

# ---- handlers that finish on a task

const UDATA_OFF = Int(ccall((:shim_udata_offset, LIB), Csize_t, ()))
const WORK = Dict{UInt,Any}()
const DONE = Dict{UInt,String}()
const resumed_c = Ref{Ptr{Cvoid}}()
const fallback_c = Ref{Ptr{Cvoid}}()
const paused_c = Ref{Ptr{Cvoid}}()

function run_async(id::UInt, handle::Ptr{Cvoid})
    lock(state_lock); w = pop!(WORK, id); unlock(state_lock)
    res = try
        w isa StreamState ? fetch(w.task) : summary(w[1], w[2])
    catch e
        string("error ", e)
    end
    lock(state_lock); DONE[id] = res; unlock(state_lock)
    ccall((:shim_resume, LIB), Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}), handle, resumed_c[], fallback_c[])
end
function paused_cb(handle::Ptr{Cvoid})::Cvoid
    id = UInt(ccall((:http_paused_udata_get, LIB), Ptr{Cvoid}, (Ptr{Cvoid},), handle))
    Threads.@spawn run_async($id, $handle)
    return nothing
end
function resumed_cb(h::Ptr{Cvoid})::Cvoid
    id = unsafe_load(Ptr{UInt}(h + UDATA_OFF))
    lock(state_lock); res = pop!(DONE, id, nothing); unlock(state_lock)
    res === nothing ? respond(h, 500, "") : respond(h, 200, res)
    return nothing
end
function fallback_cb(udata::Ptr{Cvoid})::Cvoid
    lock(state_lock); pop!(DONE, UInt(udata), nothing); unlock(state_lock)
    return nothing
end
function finish_on_task(h::Ptr{Cvoid}, work)
    id = new_id()
    lock(state_lock); WORK[id] = work; unlock(state_lock)
    unsafe_store!(Ptr{UInt}(h + UDATA_OFF), id)
    ccall((:http_pause, LIB), Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}), h, paused_c[])
end

function rss_kb()
    return parse(Int, strip(read(`ps -o rss= -p $(getpid())`, String)))
end

function on_request(h::Ptr{Cvoid})::Cvoid
    path = req_path(h)
    if path == "/json"
        return respond(h, 200, SMALL_JSON, "application/json")
    elseif path == "/tiny"
        return respond(h, 200, "")
    elseif path == "/stats"
        GC.gc(); GC.gc()
        lock(state_lock)
        s = string("roots=", length(ROOTS), " streams=", length(STREAMS), " work=", length(WORK),
                   " aborts=", ABORTS[], " pauses=", PAUSES[], " peak_queued=", PEAK_QUEUED[], " rss_kb=", rss_kb())
        unlock(state_lock)
        return respond(h, 200, s)
    end
    op, mode = parse_route(path)
    op == 0 && return respond(h, 404, "")
    op == 3 && return respond(h, 401, "")
    if !V10
        b = read_body_stock(h)
        return ASYNC ? finish_on_task(h, (op, b)) : respond(h, 200, summary(op, b))
    end
    info = body_info(h)
    if info.mode == B_STREAM
        lock(state_lock); st = pop!(STREAMS, info.udata); unlock(state_lock)
        st.ch === nothing && return respond(h, 200, result(st))
        close(st.ch)
        return finish_on_task(h, st)
    elseif (mode == 's' || mode == 't') && info.mode != 0
        # The body was complete before the headers hook could run: one piece.
        st = StreamState(op, 0, 0, 0x00, op == 2 ? SHA.SHA2_256_CTX() : nothing, nothing,
                         Threads.Atomic{Int}(0), Threads.Atomic{Bool}(false), 0, nothing, 0)
        feed!(st, info.data, Int(info.len))
        return respond(h, 200, result(st))
    elseif op == 4
        info.mode == B_FILE || return respond(h, 200, string(info.len, " inline"))
        dest = unsafe_string(info.path) * ".moved"
        mv(unsafe_string(info.path), dest)
        ccall((:http1_body_keep_file, LIB), Cvoid, (Ptr{Cvoid},), h)
        n = filesize(dest)
        rm(dest)
        return respond(h, 200, string(n, " moved"))
    end
    if mode == 'v' && (info.mode == B_MALLOC || (info.mode == B_VIEW && !ASYNC))
        # Borrowed: C frees the block when the response is finished; nothing for the GC to track.
        b = unsafe_wrap(Array, info.data, Int(info.len))
    else
        b = read_body(h, info)
    end
    return ASYNC ? finish_on_task(h, (op, b)) : respond(h, 200, summary(op, b))
end

function main()
    resumed_c[] = @cfunction(resumed_cb, Cvoid, (Ptr{Cvoid},))
    fallback_c[] = @cfunction(fallback_cb, Cvoid, (Ptr{Cvoid},))
    paused_c[] = @cfunction(paused_cb, Cvoid, (Ptr{Cvoid},))
    cb = @cfunction(on_request, Cvoid, (Ptr{Cvoid},))
    ccall((:shim_wake_init, LIB), Cint, ())
    if V10
        cfg = BodyConfig(@cfunction(headers_cb, Cvoid, (Ptr{Cvoid}, Int64, Ptr{BodyPlan})),
                         @cfunction(data_cb, Cint, (Ptr{Cvoid}, UInt, Ptr{UInt8}, Csize_t)),
                         @cfunction(abort_cb, Cvoid, (UInt, Int32)),
                         MEMLIMIT, opt("chunk", 0))
        ccall((:http1_body_configure, LIB), Cvoid, (BodyConfig,), cfg)
    end
    settings = HttpSettings(cb, C_NULL, C_NULL, C_NULL, C_NULL, C_NULL,
                            0, 0, opt("maxbody", 0), 0, C_NULL, 0, 0, 0, 0, opt("timeout", 0), 0, 0, 0)
    r = ccall((:http_listen, LIB), Int, (Cstring, Cstring, HttpSettings), PORT, "127.0.0.1", settings)
    r < 0 && error("http_listen failed")
    ccall((:shim_start_pthread, LIB), Cint, (Cint,), opt("threads", 1))
    if opt("gcloop", 0) == 1
        Threads.@spawn while true
            GC.gc()
            sleep(0.002)
        end
    end
    println("READY pid=", getpid(), " lib=", basename(LIB), " ", join(ARGS[3:end], " "))
    flush(stdout)
    while true
        sleep(3600)
    end
end
main()
