# Streamed responses: the head goes out at once (chunked on HTTP/1.1), the body
# is written piece by piece and the connection stays alive afterwards. Writes
# are addressed by connection uuid, so any thread may make them; only the
# begin step touches `h`, on the reactor.

const SW_CHUNKED, SW_LAST, SW_COPY, SW_WAKE = Cint(4), Cint(8), Cint(16), Cint(32)
const FIO_EAGER, FIO_LAZY, FIO_CORK, FIO_FLUSH = Cint(0), Cint(1), Cint(2), Cint(3)
const SB_TLS, SB_HEAD, SB_CHUNKED = Cint(1), Cint(2), Cint(4)

# Writes up to this size are copied; larger buffers are sent without a copy.
const COPY_MAX = 4096
# A task's writes are corked and sent once this much is queued (or it yields).
const FLUSH_AT = 64 * 1024

# Live streams and SSE connections by key; C callbacks find them here.
const LIVE_STREAMS = Dict{UInt,Any}()
const LIVE_STREAMS_LOCK = Threads.SpinLock()
const NEXT_STREAM = Threads.Atomic{UInt}(0)
const ON_GONE = Ref{Ptr{Cvoid}}(C_NULL)
const ON_DRAIN = Ref{Ptr{Cvoid}}(C_NULL)

# Keys double as facil.io link ids on the connection, so they carry a tag no
# heap pointer has.
const STREAM_KEY_TAG = UInt(0x5e) << 56

function register_stream!(x)
    k = (Threads.atomic_add!(NEXT_STREAM, UInt(1)) + UInt(1)) | STREAM_KEY_TAG
    lock(LIVE_STREAMS_LOCK)
    LIVE_STREAMS[k] = x
    unlock(LIVE_STREAMS_LOCK)
    k
end
unregister_stream!(k::UInt) = (lock(LIVE_STREAMS_LOCK); delete!(LIVE_STREAMS, k); unlock(LIVE_STREAMS_LOCK); nothing)
find_stream(k::UInt) = (lock(LIVE_STREAMS_LOCK); x = get(LIVE_STREAMS, k, nothing); unlock(LIVE_STREAMS_LOCK); x)

"""
    Facil.live_streams() -> Int

Streamed responses and SSE connections that are still open.
"""
live_streams() = (lock(LIVE_STREAMS_LOCK); n = length(LIVE_STREAMS); unlock(LIVE_STREAMS_LOCK); n)

function on_stream_gone(udata::Ptr{Cvoid})
    try
        x = find_stream(UInt(udata))
        x === nothing || mark_gone!(x)
    catch e
        callback_error("closing a stream", e, catch_backtrace())
    end
    nothing
end

function on_stream_drain(uuid::Int, udata::Ptr{Cvoid})
    try
        x = find_stream(UInt(udata))
        x === nothing || notify(x.drained)
    catch e
        callback_error("draining a stream", e, catch_backtrace())
    end
    nothing
end

pending_bytes(uuid::Int) = Int(@ccall LIBFJL.fio_pending_bytes(uuid::Int)::Csize_t)

fjl_stream_write(uuid::Int, p::Ptr{UInt8}, n::Integer, dealloc::Ptr{Cvoid}, flags::Cint) =
    Int(@gcsafe_ccall LIBFJL.fjl_stream_write(uuid::Int, p::Ptr{UInt8}, n::Csize_t, dealloc::Ptr{Cvoid}, flags::Cint)::Cssize_t)
fjl_stream_flush(uuid::Int, on_caller::Bool) = @gcsafe_ccall LIBFJL.fjl_stream_flush(uuid::Int, Cint(on_caller)::Cint)::Cvoid
fio_close_any(uuid::Int) = (@gcsafe_ccall LIBFJL.fio_close(uuid::Int)::Cvoid; fjl_on_reactor() || fjl_wake(); nothing)

# Queues one buffer: copied when small, otherwise pinned until facil.io is done.
function queue_bytes(uuid::Int, buf::Union{String,Vector{UInt8}}, flags::Cint)
    n = sizeof(buf)
    GC.@preserve buf begin
        p = Ptr{UInt8}(pointer(buf))
        if n <= COPY_MAX
            fjl_stream_write(uuid, p, n, C_NULL, flags | SW_COPY)
        else
            pin!(buf, p)
            fjl_stream_write(uuid, p, n, BODY_DEALLOC[], flags)
        end
    end
end

"""
    ResponseStream <: IO

The body of a streamed response, handed to the function given to
[`stream`](@ref). `write` queues bytes (strings and byte vectors over 4 KiB are
sent without a copy, so do not modify a vector after writing it), `flush`
sends what is queued, `isopen` turns false once the client has gone, after
which `write` throws an `IOError`. On a task, a write blocks while more than
`high_water` bytes wait for a slow client.
"""
mutable struct ResponseStream <: IO
    const uuid::Int
    const chunked::Bool
    const tls::Bool
    const on_task::Bool
    const high_water::Int
    const drained::Base.Event
    key::UInt
    enc::Any
    @atomic gone::Bool
    @atomic closed::Bool
    @atomic flush_due::Bool
    corked::Int
end

ResponseStream(uuid::Int, chunked::Bool, tls::Bool, on_task::Bool, high_water::Int, enc) =
    ResponseStream(uuid, chunked, tls, on_task, high_water, Base.Event(true), UInt(0), enc, false, false, false, 0)

mark_gone!(s::ResponseStream) = (@atomic s.gone = true; notify(s.drained); nothing)

Base.isopen(s::ResponseStream) = !(@atomic s.gone) && !(@atomic s.closed)
Base.iswritable(s::ResponseStream) = isopen(s)
Base.isreadable(::ResponseStream) = false
Base.eof(::ResponseStream) = true

function Base.show(io::IO, s::ResponseStream)
    print(io, "Facil.ResponseStream(", isopen(s) ? "open" : "closed", s.enc === nothing ? "" : ", compressed", ")")
end

stream_gone_error() = Base.IOError("Facil: the client closed the connection", -32)

# Mode for a body write: the reactor queues and flushes after the callback; a
# task corks on plain sockets (flushing itself) and leaves TLS to the reactor.
@inline write_mode(s::ResponseStream) =
    !s.on_task ? FIO_LAZY : s.tls ? (FIO_LAZY | SW_WAKE) : FIO_CORK

function raw_write(s::ResponseStream, buf::Union{String,Vector{UInt8}}, last::Bool = false)
    n = sizeof(buf)
    (n == 0 && !last) && return 0
    flags = write_mode(s) | (s.chunked ? SW_CHUNKED : Cint(0))
    if last
        flags = (flags & ~Cint(3)) | (s.on_task && s.tls ? FIO_LAZY : FIO_FLUSH) | SW_LAST | SW_WAKE
        s.chunked || (flags &= ~SW_LAST)
    end
    r = if n == 0
        s.chunked ? fjl_stream_write(s.uuid, Ptr{UInt8}(C_NULL), 0, C_NULL, flags) : 0
    else
        queue_bytes(s.uuid, buf, flags)
    end
    if r < 0
        @atomic s.gone = true
        throw(stream_gone_error())
    end
    last && return n
    if s.on_task && !s.tls
        s.corked += n
        if r >= FLUSH_AT
            sock_flush(s)
        else
            schedule_flush(s)
        end
    end
    s.on_task && r > s.high_water && wait_drain(s)
    n
end

function sock_flush(s::ResponseStream)
    s.corked = 0
    fjl_stream_flush(s.uuid, !s.on_task || !s.tls)
end

# Corked bytes are sent when the writing task next yields: a task pinned to
# this thread runs then and flushes, so a burst of writes leaves in one go.
function schedule_flush(s::ResponseStream)
    (@atomic s.flush_due) && return
    @atomic s.flush_due = true
    t = Task(() -> deferred_flush(s))
    t.sticky = true
    ccall(:jl_set_task_tid, Cint, (Any, Cint), t, Threads.threadid() - 1)
    schedule(t)
    nothing
end

function deferred_flush(s::ResponseStream)
    @atomic s.flush_due = false
    (isopen(s) && s.corked > 0) && sock_flush(s)
    nothing
end

"""
    Facil.wait_drain(s)

Blocks the calling task until no more than a quarter of the stream's
`high_water` bytes wait to be sent, or the client is gone. Not for the reactor.
"""
function wait_drain(s)
    low = max(s.high_water >> 2, 0)
    s isa ResponseStream && s.corked > 0 && sock_flush(s)
    while !(@atomic s.gone)
        r = @gcsafe_ccall LIBFJL.fio_drain_notify(s.uuid::Int, low::Csize_t, ON_DRAIN[]::Ptr{Cvoid}, Ptr{Cvoid}(s.key)::Ptr{Cvoid})::Cint
        r == 1 || break
        wait(s.drained)
    end
    nothing
end

Base.write(s::ResponseStream, b::String) = write_body(s, b)
Base.write(s::ResponseStream, b::Vector{UInt8}) = write_body(s, b)

function write_body(s::ResponseStream, b::Union{String,Vector{UInt8}})
    isopen(s) || throw(stream_gone_error())
    e = s.enc
    if e === nothing
        return raw_write(s, b)
    end
    GC.@preserve b encode!(z -> raw_write(s, z), e, Ptr{UInt8}(pointer(b)), sizeof(b))
    sizeof(b)
end

Base.write(s::ResponseStream, b::SubString{String}) = write(s, String(b))
Base.write(s::ResponseStream, b::UInt8) = write(s, UInt8[b])

function Base.unsafe_write(s::ResponseStream, p::Ptr{UInt8}, n::UInt)
    v = Vector{UInt8}(undef, n)
    GC.@preserve v unsafe_copyto!(pointer(v), p, n)
    write(s, v)
end

function Base.flush(s::ResponseStream)
    isopen(s) || return nothing
    e = s.enc
    e === nothing || encode_flush!(z -> raw_write(s, z), e)
    sock_flush(s)
    nothing
end

"""
    close(s::ResponseStream)

Ends the body (the terminating chunk) and lets the connection serve its next
request. Called for you when the function given to [`stream`](@ref) returns.
"""
function Base.close(s::ResponseStream)
    _, ok = @atomicreplace s.closed false => true
    ok || return nothing
    try
        if !(@atomic s.gone)
            e = s.enc
            if e === nothing
                raw_write(s, UInt8[], true)
            else
                pieces = Vector{UInt8}[]
                encode_finish!(z -> push!(pieces, z), e)
                for (i, z) in enumerate(pieces)
                    raw_write(s, z, i == length(pieces))
                end
                isempty(pieces) && raw_write(s, UInt8[], true)
            end
            s.chunked || sock_flush(s)
            @gcsafe_ccall LIBFJL.fjl_stream_end(s.uuid::Int, Ptr{Cvoid}(s.key)::Ptr{Cvoid}, Cint(s.chunked)::Cint, Cint(s.on_task ? 2 : 1)::Cint)::Cvoid
        end
    catch e
        e isa Base.IOError || rethrow()
    finally
        release!(s)
    end
    nothing
end

# Ends a body that failed half-way: closing the connection tells the client
# the response is incomplete.
function abort!(s::ResponseStream)
    _, ok = @atomicreplace s.closed false => true
    ok || return nothing
    (@atomic s.gone) || fio_close_any(s.uuid)
    release!(s)
    nothing
end

function release!(s::ResponseStream)
    e = s.enc
    e === nothing || encoder_free!(e)
    s.key == 0 || unregister_stream!(s.key)
    nothing
end

"""
Body of a streamed response; see [`stream`](@ref).
"""
struct StreamBody{F}
    f::F
    compress::Symbol
    level::Int
    spawn::Union{Nothing,Bool}
    high_water::Int
end

"""
    stream(f, req; status = 200, headers = [], compress = :auto, level = 0,
           spawn = nothing, high_water = 1 MiB) -> Response

A response whose body `f(io::ResponseStream)` writes while it is being sent;
the handler returns it. HTTP/1.1 clients get `transfer-encoding: chunked` and
keep their connection; HTTP/1.0 clients get a body ended by closing the
connection. A HEAD request gets the head only (`f` is not called).

```julia
serve!(8080) do req
    stream(req; headers = [header.CONTENT_TYPE => "text/plain"]) do io
        for i in 1:10
            write(io, "line \$i\\n")
            Facil.sleep(0.1)
        end
    end
end
```

`f` runs on its own task when the server runs task handlers (`inline = false`)
and on the reactor for inline servers; `spawn = true/false` overrides that. On
the reactor `f` must not block. If `f` throws, the connection is closed so the
client sees an incomplete body.

`compress = :gzip`, `:br` or `:zstd` compresses the body (on the thread running
`f`) and sets `content-encoding`; `:auto` follows `serve!(...; compress)` and the
request's `Accept-Encoding`; `nothing` never compresses. `level = 0` takes the
default level. A gzip body that ends within its first 128 KiB, with no `flush`,
is compressed in one pass by libdeflate; longer ones are streamed by zlib-ng.
"""
function stream(f, req = nothing; status = StatusCodes.OK, headers = HeaderMap{HeaderValue}(), compress = :auto,
                level::Integer = 0, spawn::Union{Nothing,Bool} = nothing, high_water::Integer = 1024 * 1024)
    high_water > 0 || throw(ArgumentError("high_water must be positive"))
    Response(StatusCode(status), StreamBody(f, encoding_symbol(compress), Int(level), spawn, Int(high_water)); headers)
end

function compress_response(req, res::Response{<:StreamBody}, o::CompressOptions)
    b = res.body
    b.compress === :auto || return res
    ct = content_type_of(res.headers, nothing)
    enc, varies = choose_encoding(req, res, o, isempty(ct) ? OCTET_STREAM : ct)
    varies && add_vary!(res.headers)
    lvl = b.level == 0 && enc !== :none ? level_of(o, enc) : b.level
    Response(res.status, res.version, res.headers, res.extensions, StreamBody(b.f, enc, lvl, b.spawn, b.high_water))
end

server_inline(h::Ptr{Cvoid}) = (p = fjl_server_udata(h); p == C_NULL || (unsafe_pointer_to_objref(p)::Server).options.inline)

# A body task of a task-handler server runs on its worker pool: idle workers
# wait in C, so a plain spawned task could get only the threads they leave free.
spawn_body(h::Ptr{Cvoid}, f) = server_inline(h) ? (Threads.@spawn f(); nothing) : submit(f)

@noinline function respond(h::Ptr{Cvoid}, res::Response{<:StreamBody})
    b = res.body
    hs = res.headers
    has_ct = write_headers(h, hs)
    has_ct || set_header(h, CT_ID, "content-type", OCTET_STREAM)
    enc = b.compress === :auto ? :none : b.compress
    if enc !== :none && !haskey(hs, header.CONTENT_ENCODING)
        set_header(h, HttpTypes.standard_index(header.CONTENT_ENCODING), "content-encoding", getfield(ENCODING_NAMES, enc))
    end
    info = Ref{Cint}(0)
    uuid = Int(@ccall LIBFJL.fjl_stream_begin(h::Ptr{Cvoid}, Cint(UInt16(res.status))::Cint, info::Ptr{Cint})::Int)
    if uuid == -1
        fail(h, 500)
        return nothing
    end
    on_task = b.spawn === nothing ? !server_inline(h) : b.spawn
    head = info[] & SB_HEAD != 0
    coder = (enc === :none || head) ? nothing : stream_encoder(enc, b.level == 0 ? default_level(enc) : b.level)
    s = ResponseStream(uuid, info[] & SB_CHUNKED != 0, info[] & SB_TLS != 0, on_task, b.high_water, coder)
    s.key = register_stream!(s)
    @ccall LIBFJL.fjl_stream_link(uuid::Int, Ptr{Cvoid}(s.key)::Ptr{Cvoid}, ON_GONE[]::Ptr{Cvoid})::Cint
    if head
        @atomic s.closed = true
        @gcsafe_ccall LIBFJL.fjl_stream_end(uuid::Int, Ptr{Cvoid}(s.key)::Ptr{Cvoid}, 0::Cint, 1::Cint)::Cvoid
        release!(s)
    elseif on_task
        spawn_body(h, () -> run_stream(b.f, s))
    else
        run_stream(b.f, s)
    end
    nothing
end

function run_stream(f, s::ResponseStream)
    try
        f(s)
    catch e
        (e isa Base.IOError && (@atomic s.gone)) || log_error("a streamed response", e, catch_backtrace())
        abort!(s)
        return nothing
    end
    try
        close(s)
    catch e
        log_error("ending a streamed response", e, catch_backtrace())
        abort!(s)
    end
    nothing
end

function init_streaming()
    ON_GONE[] = @cfunction(on_stream_gone, Cvoid, (Ptr{Cvoid},))
    ON_DRAIN[] = @cfunction(on_stream_drain, Cvoid, (Int, Ptr{Cvoid}))
    nothing
end
