# Request bodies: `before_body(head)` picks where a body goes as soon as its
# head is complete. Bodies that are still arriving are tracked here by id,
# from facil.io's on_headers until on_request (or on_abort).

"""
    Buffer()

`before_body` result: receive the whole body into memory, then call the handler
with it as `body(req)`. The default. Bodies over `body_in_memory` get a 413.
"""
struct Buffer end

"""
    Stream(; on_chunk = nothing, high_water = 4 MiB)
    Stream(on_chunk)

`before_body` result: the body is not kept. With `on_chunk`, each piece is passed
to `on_chunk(bytes)` on the reactor thread as it arrives (`bytes` is valid only
during the call; the function must not block), and the handler runs once the body
has ended. Without it, the pieces are read from [`body_stream(req)`](@ref) or
[`body_chunks(req)`](@ref): a task handler (`inline = false`) starts as soon as the
head arrives and reading the socket pauses while more than `high_water` bytes are
unread; an inline handler runs once the whole body has been queued.
"""
struct Stream{F}
    on_chunk::F
    high_water::Int
end
Stream(; on_chunk = nothing, high_water::Integer = 4 * 1024 * 1024) = Stream(on_chunk, Int(high_water))
Stream(on_chunk) = Stream(; on_chunk)

"""
    Spool()

`before_body` result: write the body to an unlinked temp file. The handler reads it
with [`body_stream(req)`](@ref) (an `IOStream` at position 0); `body(req)` is empty.
"""
struct Spool end

"""
    Reject(status = 413)

`before_body` result: answer `status` without reading the body and close the
connection. No `100 Continue` is sent.
"""
struct Reject
    status::Int
    function Reject(status::Integer = 413)
        400 <= status <= 599 || throw(ArgumentError("Reject needs a 4xx or 5xx status, got $status"))
        new(Int(status))
    end
end

"""
    RequestHead

What `before_body` receives: `method(head)`, `uri(head)`, `version(head)`,
`headers(head)`, and `head.content_length` (`-1` for a chunked body).
"""
struct RequestHead
    method::HttpMethod
    uri::Uri
    version::Version
    headers::HeaderMap{HeaderValue}
    content_length::Int
end
HttpTypes.method(h::RequestHead) = h.method
HttpTypes.uri(h::RequestHead) = h.uri
HttpTypes.version(h::RequestHead) = h.version
HttpTypes.headers(h::RequestHead) = h.headers

"`Facil.ischunked(head)`: the body has no declared length."
ischunked(h::RequestHead) = h.content_length < 0

default_before_body(::RequestHead) = Buffer()

# ---- the body stream handed to handlers

"Thrown while reading a request body whose connection was lost."
struct BodyAborted <: Exception end
Base.showerror(io::IO, ::BodyAborted) = print(io, "the client's connection closed before the request body ended")

"""
    BodyStream <: IO

A request body read as it arrives (`Stream()`): `read`, `readbytes!`, `eof`,
`readavailable`, and iteration over chunks with [`body_chunks`](@ref).
"""
mutable struct BodyStream <: IO
    const cond::Base.GenericCondition{Threads.SpinLock}
    const queue::Vector{Vector{UInt8}}
    head::Int
    queued::Int
    received::Int
    done::Bool
    aborted::Bool
    discard::Bool
    paused::Bool
    const pausable::Bool
    const high_water::Int
    const uuid::Int
    cur::Vector{UInt8}
    pos::Int
end

BodyStream(; pausable::Bool = false, high_water::Int = 4 << 20, uuid::Int = -1) =
    BodyStream(Base.GenericCondition(Threads.SpinLock()), Vector{UInt8}[], 1, 0, 0, false, false, false,
               false, pausable, high_water, uuid, UInt8[], 1)

body_resume(uuid::Int) = @ccall LIBFJL.fjl_body_resume(uuid::Int)::Cvoid

# Reactor side. Returns 1 when reading should pause.
function push_chunk!(s::BodyStream, chunk::Vector{UInt8})
    pause = false
    lock(s.cond)
    try
        s.received += length(chunk)
        if !s.discard
            push!(s.queue, chunk)
            s.queued += length(chunk)
            pause = s.pausable && s.queued > s.high_water
            s.paused |= pause
            notify(s.cond)
        end
    finally
        unlock(s.cond)
    end
    Cint(pause)
end

function finish!(s::BodyStream; aborted::Bool = false)
    lock(s.cond)
    s.done = true
    s.aborted |= aborted
    notify(s.cond)
    unlock(s.cond)
    nothing
end

# Drops everything unread, now and later, and lets the upload finish.
function discard!(s::BodyStream)
    lock(s.cond)
    s.discard = true
    empty!(s.queue)
    s.head = 1
    s.queued = 0
    resume = s.paused
    s.paused = false
    notify(s.cond)
    unlock(s.cond)
    resume && body_resume(s.uuid)
    s.cur = UInt8[]
    s.pos = 1
    nothing
end

function take_chunk!(s::BodyStream)
    resume = false
    lock(s.cond)
    local c
    try
        while s.head > length(s.queue) && !s.done && !s.discard
            wait(s.cond)
        end
        if s.head > length(s.queue)
            s.aborted && !s.discard && throw(BodyAborted())
            return nothing
        end
        c = s.queue[s.head]
        s.queue[s.head] = UInt8[]
        s.head += 1
        if s.head > 64 && 2s.head > length(s.queue)
            deleteat!(s.queue, 1:s.head-1)
            s.head = 1
        end
        s.queued -= length(c)
        if s.paused && s.queued <= s.high_water ÷ 2
            s.paused = false
            resume = true
        end
    finally
        unlock(s.cond)
    end
    resume && body_resume(s.uuid)
    c
end

function fill_cur!(s::BodyStream)
    while s.pos > length(s.cur)
        c = take_chunk!(s)
        c === nothing && return false
        s.cur, s.pos = c, 1
    end
    true
end

Base.eof(s::BodyStream) = !fill_cur!(s)
Base.isopen(s::BodyStream) = !(s.discard || (s.done && s.pos > length(s.cur) && s.head > length(s.queue)))
Base.close(s::BodyStream) = discard!(s)
Base.bytesavailable(s::BodyStream) = length(s.cur) - s.pos + 1

function Base.read(s::BodyStream, ::Type{UInt8})
    fill_cur!(s) || throw(EOFError())
    b = @inbounds s.cur[s.pos]
    s.pos += 1
    b
end

function Base.unsafe_read(s::BodyStream, p::Ptr{UInt8}, n::UInt)
    while n > 0
        fill_cur!(s) || throw(EOFError())
        k = min(Int(n), length(s.cur) - s.pos + 1)
        GC.@preserve s unsafe_copyto!(p, pointer(s.cur, s.pos), k)
        s.pos += k
        p += k
        n -= k
    end
    nothing
end

function Base.readbytes!(s::BodyStream, b::AbstractVector{UInt8}, nb = length(b))
    n = 0
    while n < nb && fill_cur!(s)
        k = min(nb - n, length(s.cur) - s.pos + 1)
        n + k > length(b) && resize!(b, n + k)
        copyto!(b, n + 1, s.cur, s.pos, k)
        s.pos += k
        n += k
    end
    n
end

function Base.readavailable(s::BodyStream)
    fill_cur!(s) || return UInt8[]
    c = s.pos == 1 ? s.cur : s.cur[s.pos:end]
    s.cur, s.pos = UInt8[], 1
    c
end

function Base.read(s::BodyStream)
    out = IOBuffer()
    while fill_cur!(s)
        write(out, readavailable(s))
    end
    take!(out)
end

"`body_chunks(req)` iterates over the body as `Vector{UInt8}` pieces, in arrival order."
struct BodyChunks
    io::IO
end
Base.IteratorSize(::Type{BodyChunks}) = Base.SizeUnknown()
Base.eltype(::Type{BodyChunks}) = Vector{UInt8}
function Base.iterate(c::BodyChunks, st = nothing)
    io = c.io
    if io isa BodyStream
        fill_cur!(io) || return nothing
        return (readavailable(io)::Vector{UInt8}, nothing)
    end
    eof(io) && return nothing
    (readavailable(io)::Vector{UInt8}, nothing)
end

# How a request's body can be read besides body(req); kept in its extensions.
struct BodyIO
    io::IO
end
# The handler task started at the head of a streamed request (task handlers).
# Whichever comes second of the handler returning (flag 1) and the request
# being paused at the end of its body (flag 2) hands the result to the reactor.
mutable struct StreamRun
    @atomic flags::Int
    res::Any
    a::Ptr{Cvoid}
    id::UInt64
end
struct StreamTask
    run::StreamRun
end

"""
    body_stream(req) -> IO

The request body as an `IO`: a [`BodyStream`](@ref) for `Stream()`, an `IOStream`
for `Spool()`, and an `IOBuffer` over `body(req)` otherwise.
"""
function body_stream(req::Request)
    b = get(extensions(req), BodyIO, nothing)
    b === nothing ? IOBuffer(body(req)) : b.io
end

"""
    body_chunks(req)

Iterates over the request body as `Vector{UInt8}` pieces; see [`body_stream`](@ref).
"""
body_chunks(req::Request) = BodyChunks(body_stream(req))

stream_task(req::Request) = (t = get(extensions(req), StreamTask, nothing); t === nothing ? nothing : t.run)

# ---- C mirrors

const B_NONE, B_VIEW, B_MALLOC, B_EXTERN, B_STREAM, B_FILE = Int32.(0:5)

struct BodyPlanC
    mode::Int32
    status::Int32
    dest::Ptr{UInt8}
    udata::Ptr{Cvoid}
    mem_limit::Csize_t
end

struct BodyInfoC
    mode::Int32
    fd::Int32
    data::Ptr{UInt8}
    len::Csize_t
    udata::Ptr{Cvoid}
    path::Ptr{UInt8}
end

function body_info(h::Ptr{Cvoid})
    r = Ref{BodyInfoC}()
    @ccall LIBFJL.http1_body_info(h::Ptr{Cvoid}, r::Ptr{BodyInfoC})::Cint
    r[]
end

reject_now(h::Ptr{Cvoid}, status::Integer) = (@ccall LIBFJL.fjl_body_reject(h::Ptr{Cvoid}, Cint(status)::Cint)::Cint; nothing)

# ---- bodies in flight

const K_FIXED, K_CHUNKED, K_CALLBACK, K_QUEUE, K_SPOOL = 0x01, 0x02, 0x03, 0x04, 0x05

mutable struct PendingBody
    const srv::Server
    const head::RequestHead
    const kind::UInt8
    vec::Vector{UInt8}
    blocks::Vector{Vector{UInt8}}
    file::Union{IOStream,Nothing}
    nbytes::Int
    over::Bool
    failed::Bool
    on_chunk::Any
    stream::Union{BodyStream,Nothing}
    req::Union{Request{String},Nothing}
end

PendingBody(srv, head, kind) = PendingBody(srv, head, kind, UInt8[], Vector{UInt8}[], nothing, 0, false, false, nothing, nothing, nothing)

const BODY_SHARDS = 16
const PENDING = [Dict{UInt,PendingBody}() for _ in 1:BODY_SHARDS]
const PENDING_LOCKS = [Threads.SpinLock() for _ in 1:BODY_SHARDS]
const BODY_NEXT = Threads.Atomic{UInt}(0)
const BODY_ABORTS = Threads.Atomic{Int}(0)

@inline body_shard(id::UInt) = (id % BODY_SHARDS) % Int + 1

function put_pending!(st::PendingBody)
    id = Threads.atomic_add!(BODY_NEXT, UInt(1)) + UInt(1)
    i = body_shard(id)
    lock(@inbounds PENDING_LOCKS[i])
    @inbounds PENDING[i][id] = st
    unlock(@inbounds PENDING_LOCKS[i])
    id
end

function get_pending(id::UInt; remove::Bool = false)
    i = body_shard(id)
    l = @inbounds PENDING_LOCKS[i]
    lock(l)
    st = remove ? pop!(@inbounds(PENDING[i]), id, nothing) : get(@inbounds(PENDING[i]), id, nothing)
    unlock(l)
    st
end

"`Facil.pending_bodies()`: request bodies being received (none once every upload has ended)."
pending_bodies() = sum(i -> (lock(PENDING_LOCKS[i]); n = length(PENDING[i]); unlock(PENDING_LOCKS[i]); n), 1:BODY_SHARDS)

function read_head(h::Ptr{Cvoid}, content_length::Integer)
    r = unsafe_load(@ccall LIBFJL.fjl_req_read(h::Ptr{Cvoid})::Ptr{CRequest})
    m = HttpMethod(r.method.ptr, r.method.len)
    u = HttpTypes.uri_from_target(r.path.ptr, r.path.len, r.query.ptr, r.query.len)
    v = 1 <= r.version <= 5 ? @inbounds(VERSIONS[r.version]) : Versions.HTTP_11
    n = Int(r.nheaders)
    hm = HeaderMap{HeaderValue}(n)
    for i in 1:n
        c = unsafe_load(r.headers, i)
        name = c.code != 0 ? HttpTypes.standard_header(c.code) : HeaderName(c.name.ptr, c.name.len)
        append!(hm, name, HttpTypes.unchecked(HeaderValue, c.value.ptr, c.value.len))
    end
    RequestHead(m, u, v, hm, Int(content_length))
end

new_request(head::RequestHead, body::String) =
    Request(head.method, head.uri, head.version, head.headers, Extensions(), body)

function decide(@nospecialize(srv::Server), head::RequestHead)
    f = srv.options.before_body
    f === default_before_body && return Buffer()
    d = f(head)
    d isa Union{Buffer,Stream,Spool,Reject} ||
        throw(ArgumentError("before_body returned a $(typeof(d)); expected Buffer(), Stream(), Spool() or Reject(status)"))
    d
end

note(@nospecialize(srv::Server), msg) = srv.options.verbose && log_line(msg)
log_line(msg::AbstractString) = (m = string("Facil: ", msg, "\n"); ccall(:write, Cssize_t, (Cint, Ptr{UInt8}, Csize_t), 2, m, sizeof(m)); nothing)

function body_server(h::Ptr{Cvoid})
    p = @ccall LIBFJL.fjl_body_server(h::Ptr{Cvoid}, ON_REQUEST[]::Ptr{Cvoid})::Ptr{Cvoid}
    p == C_NULL ? nothing : unsafe_pointer_to_objref(p)::Server
end

set_plan!(planp::Ptr{BodyPlanC}, mode::Int32, status::Integer = 0, dest::Ptr{UInt8} = Ptr{UInt8}(C_NULL),
          udata::UInt = UInt(0), mem_limit = typemax(Csize_t)) =
    unsafe_store!(planp, BodyPlanC(mode, Int32(status), dest, Ptr{Cvoid}(udata), mem_limit))

function on_body_headers(h::Ptr{Cvoid}, clen::Int64, planp::Ptr{BodyPlanC})
    try
        srv = body_server(h)
        srv === nothing || plan_body!(srv, h, clen, planp)
    catch e
        log_error("before_body", e, catch_backtrace())
        set_plan!(planp, B_MALLOC, 500)
    end
    nothing
end

function plan_body!(@nospecialize(srv::Server), h::Ptr{Cvoid}, clen::Int64, planp::Ptr{BodyPlanC})
    head = read_head(h, clen)
    d = decide(srv, head)
    if d isa Reject
        note(srv, "rejected $(head.method) $(head.uri) with $(d.status) before its body")
        set_plan!(planp, B_MALLOC, d.status)
    elseif d isa Buffer
        limit = srv.options.body_in_memory
        if clen > limit
            note(srv, "413 for $(head.method) $(head.uri): $clen bytes is over body_in_memory = $limit")
            set_plan!(planp, B_MALLOC, 413)
        elseif clen >= 0
            st = PendingBody(srv, head, K_FIXED)
            st.vec = Base.StringVector(clen)
            id = put_pending!(st)
            set_plan!(planp, B_EXTERN, 0, pointer(st.vec), id)
        else
            st = PendingBody(srv, head, K_CHUNKED)
            set_plan!(planp, B_STREAM, 0, Ptr{UInt8}(C_NULL), put_pending!(st))
        end
    elseif d isa Spool
        st = PendingBody(srv, head, K_SPOOL)
        st.file = unlinked_tempfile()
        set_plan!(planp, B_STREAM, 0, Ptr{UInt8}(C_NULL), put_pending!(st))
    else
        s = d::Stream
        if s.on_chunk !== nothing
            st = PendingBody(srv, head, K_CALLBACK)
            st.on_chunk = s.on_chunk
        else
            st = PendingBody(srv, head, K_QUEUE)
            early = !srv.options.inline
            uuid = Int(@ccall LIBFJL.http1_body_uuid(h::Ptr{Cvoid})::Int)
            st.stream = BodyStream(; pausable = early, high_water = s.high_water, uuid)
            early && start_stream_handler!(srv, st)
        end
        set_plan!(planp, B_STREAM, 0, Ptr{UInt8}(C_NULL), put_pending!(st))
    end
    nothing
end

# Task handlers read a streamed body while it arrives: the handler starts now and
# its result is collected once the body has ended (see handle_stream_async).
function start_stream_handler!(@nospecialize(srv::Server), st::PendingBody)
    req = new_request(st.head, "")
    s = st.stream::BodyStream
    insert!(extensions(req), BodyIO(s))
    r = StreamRun(0, nothing, C_NULL, UInt64(0))
    Threads.@spawn begin
        r.res = try
            srv.handler(req)
        catch e
            e isa BodyAborted || log_error("a request handler", e, catch_backtrace())
            HandlerFailed()
        finally
            discard!(s)
        end
        modifyfield!(r, :flags, |, 1, :acquire_release).first & 2 == 0 || finish_stream!(r)
    end
    insert!(extensions(req), StreamTask(r))
    st.req = req
    nothing
end

function finish_stream!(r::StreamRun)
    put_result!(r.id, r.res)
    r.res = nothing
    async_done(r.a)
    nothing
end

function handle_stream_async(@nospecialize(srv::Server), h::Ptr{Cvoid}, req::Request, r::StreamRun)
    id = Threads.atomic_add!(NEXT_ID, UInt64(1)) + UInt64(1)
    a = async_pause(h, id)
    if a == C_NULL
        fail(h, 503)
        return nothing
    end
    r.id, r.a = id, a
    modifyfield!(r, :flags, |, 2, :acquire_release).first & 1 == 0 || finish_stream!(r)
    nothing
end

function on_body_data(h::Ptr{Cvoid}, udata::Ptr{Cvoid}, p::Ptr{UInt8}, n::Csize_t)
    try
        st = get_pending(UInt(udata))
        st === nothing && return Cint(0)
        return feed!(st, p, Int(n))
    catch e
        callback_error("receiving a request body", e, catch_backtrace())
    end
    Cint(0)
end

function feed!(st::PendingBody, p::Ptr{UInt8}, n::Int)
    k = st.kind
    if k == K_CHUNKED
        st.over && return Cint(0)
        if st.nbytes + n > st.srv.options.body_in_memory
            st.over = true
            release_blocks!(st)
        else
            append_blocks!(st, p, n)
        end
    elseif k == K_QUEUE
        chunk = new_chunk(n)
        unsafe_copyto!(pointer(chunk), p, n)
        return push_chunk!(st.stream::BodyStream, chunk)
    elseif k == K_SPOOL
        st.failed && return Cint(0)
        try
            unsafe_write(st.file::IOStream, p, n)
        catch e
            st.failed = true
            log_error("spooling a request body", e, catch_backtrace())
        end
    elseif k == K_CALLBACK
        st.failed && return Cint(0)
        try
            st.on_chunk(unsafe_wrap(Array, p, n))
        catch e
            st.failed = true
            log_error("a Stream on_chunk callback", e, catch_backtrace())
        end
    end
    Cint(0)
end

# Streamed chunks of 32 KiB and more live in pooled blocks: allocating a fresh
# block per socket read, and freeing it in a collection, costs more than the
# copy. A block returns to the pool when its chunk is collected; while
# `CHUNK_MAX` bytes are out, chunks are plain arrays again. Up to `CHUNK_KEEP`
# bytes of each size stay pooled.
const CHUNK_MIN = 32 << 10
const CHUNK_CLASSES = 4
const CHUNK_MAX = 64 << 20
const CHUNK_KEEP = 32 << 20
const CHUNK_FREE = [Ptr{UInt8}[] for _ in 1:CHUNK_CLASSES]
const CHUNK_LOCK = Threads.SpinLock()
const CHUNK_BYTES = Ref(0)

chunk_class(n::Int) = n < CHUNK_MIN ? 0 : (c = 65 - leading_zeros(cld(n, CHUNK_MIN) - 1); c <= CHUNK_CLASSES ? c : 0)

@static if isdefined(Base, :Memory)
    chunk_owner(v::Vector{UInt8}) = v.ref.mem
else
    chunk_owner(v::Vector{UInt8}) = v
end

function new_chunk(n::Int)
    c = chunk_class(n)
    c == 0 && return Vector{UInt8}(undef, n)
    size = CHUNK_MIN << (c - 1)
    fresh = false
    lock(CHUNK_LOCK)
    fl = @inbounds CHUNK_FREE[c]
    p = isempty(fl) ? Ptr{UInt8}(C_NULL) : pop!(fl)
    if p == C_NULL && CHUNK_BYTES[] + size <= CHUNK_MAX
        CHUNK_BYTES[] += size
        fresh = true
    end
    unlock(CHUNK_LOCK)
    if fresh
        p = Ptr{UInt8}(Libc.malloc(size))
        p == C_NULL && (drop_chunk_bytes(size); return Vector{UInt8}(undef, n))
    elseif p == C_NULL
        return Vector{UInt8}(undef, n)
    end
    v = unsafe_wrap(Array, p, n; own = false)
    finalizer(_ -> give_back_chunk(p, c), chunk_owner(v))
    v
end

drop_chunk_bytes(size) = (lock(CHUNK_LOCK); CHUNK_BYTES[] -= size; unlock(CHUNK_LOCK); nothing)

# Runs as a finalizer: no task switch, and no allocation while the lock is held.
function give_back_chunk(p::Ptr{UInt8}, c::Int)
    fl = @inbounds CHUNK_FREE[c]
    lock(CHUNK_LOCK)
    kept = length(fl) < CHUNK_KEEP ÷ (CHUNK_MIN << (c - 1))
    kept && push!(fl, p)
    kept || (CHUNK_BYTES[] -= CHUNK_MIN << (c - 1))
    unlock(CHUNK_LOCK)
    kept || Libc.free(p)
    nothing
end

# Chunked bodies of unknown length are collected in reused blocks and copied
# once into a string of the final size.
const BLOCK_SIZE = 1 << 20
const BLOCK_POOL_MAX = 128
const BLOCK_POOL = Vector{UInt8}[]
const BLOCK_POOL_LOCK = Threads.SpinLock()

function take_block()
    lock(BLOCK_POOL_LOCK)
    b = isempty(BLOCK_POOL) ? nothing : pop!(BLOCK_POOL)
    unlock(BLOCK_POOL_LOCK)
    b === nothing ? Vector{UInt8}(undef, BLOCK_SIZE) : b
end

function release_blocks!(st::PendingBody)
    isempty(st.blocks) && return nothing
    lock(BLOCK_POOL_LOCK)
    for b in st.blocks
        length(BLOCK_POOL) < BLOCK_POOL_MAX && push!(BLOCK_POOL, b)
    end
    unlock(BLOCK_POOL_LOCK)
    empty!(st.blocks)
    nothing
end

function append_blocks!(st::PendingBody, p::Ptr{UInt8}, n::Int)
    while n > 0
        off = st.nbytes % BLOCK_SIZE
        off == 0 && push!(st.blocks, take_block())
        k = min(n, BLOCK_SIZE - off)
        GC.@preserve st unsafe_copyto!(pointer(st.blocks[end], off + 1), p, k)
        st.nbytes += k
        p += k
        n -= k
    end
    nothing
end

function gather_blocks!(st::PendingBody)
    v = Base.StringVector(st.nbytes)
    left, at = st.nbytes, 1
    for b in st.blocks
        k = min(left, BLOCK_SIZE)
        copyto!(v, at, b, 1, k)
        at += k
        left -= k
    end
    release_blocks!(st)
    v
end

function on_body_abort(udata::Ptr{Cvoid}, mode::Int32)
    try
        st = get_pending(UInt(udata); remove = true)
        Threads.atomic_add!(BODY_ABORTS, 1)
        st === nothing && return nothing
        st.stream === nothing || finish!(st.stream; aborted = true)
        st.file === nothing || close(st.file)
        release_blocks!(st)
    catch e
        callback_error("an aborted request body", e, catch_backtrace())
    end
    nothing
end

"""
    read_request(srv, h) -> Union{Request{String},Nothing}

The request on `h` with its body as `before_body` chose. `nothing` when the
request has already been answered (rejected, or over a limit).
"""
function read_request(@nospecialize(srv::Server), h::Ptr{Cvoid})
    info = body_info(h)
    mode = info.mode
    if mode == B_NONE
        return read_request(h)
    elseif mode == B_VIEW
        if srv.options.before_body === default_before_body && Int(info.len) <= srv.options.body_in_memory
            req = read_request(h)
            req.body = unsafe_string(info.data, info.len)
            return req
        end
        return complete_view(srv, h, info)
    end
    st = info.udata == C_NULL ? nothing : get_pending(UInt(info.udata); remove = true)
    st === nothing && (fail(h, 500); return nothing)
    complete(st, h, info)
end

function complete(st::PendingBody, h::Ptr{Cvoid}, info::BodyInfoC)
    k = st.kind
    if k == K_FIXED
        v = st.vec
        length(v) == info.len || resize!(v, info.len)
        return new_request(st.head, String(v))
    elseif k == K_CHUNKED
        if st.over
            note(st.srv, "413 for $(st.head.method) $(st.head.uri): chunked body over body_in_memory = $(st.srv.options.body_in_memory)")
            reject_now(h, 413)
            return nothing
        end
        return new_request(st.head, String(gather_blocks!(st)))
    elseif k == K_CALLBACK
        st.failed && (reject_now(h, 500); return nothing)
        req = new_request(st.head, "")
        s = BodyStream()
        s.received = Int(info.len)
        finish!(s)
        insert!(extensions(req), BodyIO(s))
        return req
    elseif k == K_QUEUE
        s = st.stream::BodyStream
        finish!(s)
        st.req === nothing || return st.req
        req = new_request(st.head, "")
        insert!(extensions(req), BodyIO(s))
        return req
    end
    io = st.file::IOStream
    if st.failed
        close(io)
        reject_now(h, 500)
        return nothing
    end
    seekstart(io)
    req = new_request(st.head, "")
    insert!(extensions(req), BodyIO(io))
    req
end

function unlinked_tempfile()
    path, io = mktemp(; cleanup = false)
    rm(path)
    io
end

# The whole body arrived with its head, so before_body runs now.
function complete_view(@nospecialize(srv::Server), h::Ptr{Cvoid}, info::BodyInfoC)
    n = Int(info.len)
    head = read_head(h, n)
    d = try
        decide(srv, head)
    catch e
        log_error("before_body", e, catch_backtrace())
        reject_now(h, 500)
        return nothing
    end
    if d isa Reject
        note(srv, "rejected $(head.method) $(head.uri) with $(d.status)")
        reject_now(h, d.status)
        return nothing
    elseif d isa Buffer
        if n > srv.options.body_in_memory
            note(srv, "413 for $(head.method) $(head.uri): $n bytes is over body_in_memory")
            reject_now(h, 413)
            return nothing
        end
        return new_request(head, unsafe_string(info.data, n))
    elseif d isa Spool
        io = unlinked_tempfile()
        unsafe_write(io, info.data, n)
        seekstart(io)
        req = new_request(head, "")
        insert!(extensions(req), BodyIO(io))
        return req
    end
    s = d::Stream
    req = new_request(head, "")
    bs = BodyStream()
    if s.on_chunk !== nothing
        try
            s.on_chunk(unsafe_wrap(Array, info.data, n))
        catch e
            log_error("a Stream on_chunk callback", e, catch_backtrace())
            reject_now(h, 500)
            return nothing
        end
        bs.received = n
    else
        chunk = Vector{UInt8}(undef, n)
        unsafe_copyto!(pointer(chunk), info.data, n)
        push_chunk!(bs, chunk)
    end
    finish!(bs)
    insert!(extensions(req), BodyIO(bs))
    req
end

const ON_BODY_HEADERS = Ref{Ptr{Cvoid}}(C_NULL)
const ON_BODY_DATA = Ref{Ptr{Cvoid}}(C_NULL)
const ON_BODY_ABORT = Ref{Ptr{Cvoid}}(C_NULL)

function init_body()
    for c in 1:CHUNK_CLASSES
        sizehint!(CHUNK_FREE[c], CHUNK_KEEP ÷ (CHUNK_MIN << (c - 1)))
    end
    (@ccall LIBFJL.fjl_sizeof_body_plan()::Csize_t) == sizeof(BodyPlanC) || error("Facil: http1_body_plan_s size mismatch")
    (@ccall LIBFJL.fjl_sizeof_body_info()::Csize_t) == sizeof(BodyInfoC) || error("Facil: http1_body_info_s size mismatch")
    ON_BODY_HEADERS[] = @cfunction(on_body_headers, Cvoid, (Ptr{Cvoid}, Int64, Ptr{BodyPlanC}))
    ON_BODY_DATA[] = @cfunction(on_body_data, Cint, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{UInt8}, Csize_t))
    ON_BODY_ABORT[] = @cfunction(on_body_abort, Cvoid, (Ptr{Cvoid}, Int32))
    @ccall LIBFJL.fjl_body_configure(ON_BODY_HEADERS[]::Ptr{Cvoid}, ON_BODY_DATA[]::Ptr{Cvoid}, ON_BODY_ABORT[]::Ptr{Cvoid},
                                     typemax(Csize_t)::Csize_t, 0::Csize_t)::Cint
    nothing
end
