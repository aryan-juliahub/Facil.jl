# usage: julia -t 2 server.jl <port> [host]
# env: THREADS=1 reactor threads   GATHER=1 (0 = one packet per write, as stock)
#      TLS=1   GCLOOP=1   NOROOT=1 (negative control)   HIGH/LOW backpressure marks in bytes   COPYMAX chunk bytes copied instead of rooted
#
# /w/<copy|two|gather>/<bytes>     whole response, 'x' filled   (/wp/ patterned, /wf/ fresh buffer per request)
# /s/<kind>/<chunks>/<kb>          chunked stream, 'x' filled static chunk
# /p/<kind>/<chunks>/<bytes>       chunked stream, fresh self-describing chunk per write
#   kinds, new write path:  r (in the handler)  t1 (task, reactor flushes)  t2 (task flushes itself)
#                           rslow t1slow t2slow (1 ms between chunks)  tnb (task, backpressure ignored)
#   kinds, copying baseline: stock keep cork slowkeep
const HERE = @__DIR__
const TLS = get(ENV, "TLS", "0") == "1"
const LIB = ENV["FIO_LIB"]
const PORT = ARGS[1]
const RTHREADS = parse(Int, get(ENV, "THREADS", "1"))
const HIGH = parse(Int, get(ENV, "HIGH", string(2 << 20)))
const LOW = parse(Int, get(ENV, "LOW", string(256 << 10)))
const COPYMAX = parse(Int, get(ENV, "COPYMAX", "0"))
const FLUSH_AT = 64 << 10

struct HttpSettings
    on_request::Ptr{Cvoid}; on_upgrade::Ptr{Cvoid}; on_response::Ptr{Cvoid}; on_finish::Ptr{Cvoid}
    udata::Ptr{Cvoid}; public_folder::Ptr{Cchar}; public_folder_length::Csize_t
    max_header_size::Csize_t; max_body_size::Csize_t; max_clients::Int; tls::Ptr{Cvoid}
    reserved1::Int; reserved2::Int; reserved3::Int; ws_max_msg_size::Csize_t
    timeout::UInt8; ws_timeout::UInt8; log::UInt8; is_client::UInt8
end
struct FioStartArgs; threads::Int16; workers::Int16; end
struct Slice; ptr::Ptr{UInt8}; len::Csize_t; end
Slice(s::Union{String,Vector{UInt8}}) = Slice(pointer(s), sizeof(s))
const Headers = Vector{Pair{String,String}}
const Chunk = Union{String,Vector{UInt8}}

# Every call into facil.io that can take one of its spin locks is made
# gc_safe: the lock's holder may be parked at a GC safepoint on its way into
# a Julia callback, and a collection waits for every thread not marked safe.
# ---- buffers lent to the socket, keyed by address; counted because one
# buffer can be in flight on many connections at once.
const ROOTS = Dict{Ptr{Cvoid},Tuple{Chunk,Int}}()
const ROOT_LOCK = Threads.SpinLock()
const N_ROOTED = Threads.Atomic{Int}(0)
const N_RELEASED = Threads.Atomic{Int}(0)
const N_MISS = Threads.Atomic{Int}(0)

const NOROOT = get(ENV, "NOROOT", "0") == "1"   # negative control: lend buffers without keeping them alive
function root!(b::Chunk)
    p = Ptr{Cvoid}(pointer(b))
    NOROOT && return p
    lock(ROOT_LOCK)
    _, c = get(ROOTS, p, (b, 0))
    ROOTS[p] = (b, c + 1)
    unlock(ROOT_LOCK)
    Threads.atomic_add!(N_ROOTED, 1)
    return p
end
function on_dealloc(p::Ptr{Cvoid})::Cvoid
    lock(ROOT_LOCK)
    e = get(ROOTS, p, nothing)
    if e === nothing
        Threads.atomic_add!(N_MISS, 1)
    elseif e[2] == 1
        delete!(ROOTS, p)
    else
        ROOTS[p] = (e[1], e[2] - 1)
    end
    unlock(ROOT_LOCK)
    Threads.atomic_add!(N_RELEASED, 1)
    return nothing
end
const C_DEALLOC = Ref{Ptr{Cvoid}}()

# ---- whole responses
function respond(h::Ptr{Cvoid}, status::Int, hs::Headers, body::Chunk, mode::Int = 0)
    n = length(hs)
    names = Vector{Slice}(undef, n); values = Vector{Slice}(undef, n)
    GC.@preserve hs body begin
        @inbounds for i in 1:n
            names[i] = Slice(hs[i].first); values[i] = Slice(hs[i].second)
        end
        if mode == 0 || sizeof(body) == 0
            @ccall gc_safe=true LIB.shim_respond(h::Ptr{Cvoid}, status::Cint, names::Ptr{Slice}, values::Ptr{Slice}, n::Cint, body::Ptr{UInt8}, sizeof(body)::Csize_t)::Cint
        else
            p = root!(body)
            @ccall gc_safe=true LIB.shim_respond_nocopy(h::Ptr{Cvoid}, status::Cint, names::Ptr{Slice}, values::Ptr{Slice}, n::Cint, p::Ptr{Cvoid}, sizeof(body)::Csize_t, C_DEALLOC[]::Ptr{Cvoid}, (mode == 2)::Cint)::Cint
        end
    end
    nothing
end

# ---- streams, new write path
const LAZY = Cint(1); const CORK = Cint(2); const FLUSH = Cint(3); const COPY = Cint(8); const WAKE = Cint(16)

mutable struct Stream
    uuid::Int
    const id::Int
    const how::Cint          # 0 inside the handler, 1 elsewhere on the reactor, 2 another thread
    const selfflush::Bool
    const high::Int
    @atomic gone::Bool
    const drained::Base.Event
end
const STREAMS = Dict{Int,Stream}()
const STREAMS_LOCK = Threads.SpinLock()
const STREAM_SEQ = Threads.Atomic{Int}(0)
const N_WAITS = Threads.Atomic{Int}(0)
const MAX_PENDING = Threads.Atomic{Int}(0)
const C_GONE = Ref{Ptr{Cvoid}}(); const C_DRAIN = Ref{Ptr{Cvoid}}()

function stream_by_id(id::Int)
    lock(STREAMS_LOCK); s = get(STREAMS, id, nothing); unlock(STREAMS_LOCK); s
end
function on_gone(ud::Ptr{Cvoid})::Cvoid
    s = stream_by_id(Int(ud))
    if s !== nothing
        @atomic s.gone = true
        notify(s.drained)
    end
    nothing
end
function on_drain(uuid::Int, ud::Ptr{Cvoid})::Cvoid
    s = stream_by_id(Int(ud))
    s === nothing || notify(s.drained)
    nothing
end

function open_stream(h::Ptr{Cvoid}, how::Integer, selfflush::Bool = false, high::Int = HIGH)
    id = Threads.atomic_add!(STREAM_SEQ, 1) + 1
    s = Stream(0, id, how, selfflush, high, false, Base.Event(true))
    lock(STREAMS_LOCK); STREAMS[id] = s; unlock(STREAMS_LOCK)
    s.uuid = @ccall gc_safe=true LIB.shim_stream_begin(h::Ptr{Cvoid}, (selfflush ? CORK : LAZY)::Cint, Ptr{Cvoid}(id)::Ptr{Cvoid}, C_GONE[]::Ptr{Cvoid})::Int
    s.uuid == -1 && (@atomic s.gone = true)
    return s
end

pending(s::Stream) = Int(ccall((:fio_pending_bytes, LIB), Csize_t, (Int,), s.uuid))
Base.flush(s::Stream) = @ccall gc_safe=true LIB.shim_flush(s.uuid::Int, (s.how == 2)::Cint)::Cvoid

# Blocks the calling task until the connection's queue is down to LOW bytes
# (or the connection is gone). Never call it on the reactor thread.
function wait_drain(s::Stream)
    while !(@atomic s.gone)
        r = @ccall gc_safe=true LIB.fio_drain_notify(s.uuid::Int, LOW::Csize_t, C_DRAIN[]::Ptr{Cvoid}, Ptr{Cvoid}(s.id)::Ptr{Cvoid})::Cint
        r == 1 || break
        Threads.atomic_add!(N_WAITS, 1)
        wait(s.drained)
    end
    nothing
end

# Returns the bytes accepted, or -1 once the connection is gone.
function Base.write(s::Stream, c::Chunk)
    n = sizeof(c)
    n == 0 && return 0
    (@atomic s.gone) && return -1
    flags = s.how == 2 ? (s.selfflush ? CORK : LAZY | WAKE) : LAZY
    r = if n <= COPYMAX
        GC.@preserve c @ccall gc_safe=true LIB.shim_stream_write(s.uuid::Int, pointer(c)::Ptr{UInt8}, n::Csize_t, C_NULL::Ptr{Cvoid}, (flags | COPY)::Cint)::Cssize_t
    else
        @ccall gc_safe=true LIB.shim_stream_write(s.uuid::Int, root!(c)::Ptr{Cvoid}, n::Csize_t, C_DEALLOC[]::Ptr{Cvoid}, flags::Cint)::Cssize_t
    end
    if r < 0
        @atomic s.gone = true
        return -1
    end
    r > MAX_PENDING[] && (MAX_PENDING[] = r)
    if s.how == 2
        s.selfflush && r >= FLUSH_AT && flush(s)
        if r > s.high && (!s.selfflush || pending(s) > s.high)
            wait_drain(s)
        end
    end
    return n
end

function Base.close(s::Stream)
    if !(@atomic s.gone)
        mode = s.how == 0 ? FLUSH : s.how == 1 ? LAZY : s.selfflush ? FLUSH | WAKE : LAZY | WAKE
        @ccall gc_safe=true LIB.shim_stream_last(s.uuid::Int, mode::Cint)::Cssize_t
        @ccall gc_safe=true LIB.shim_stream_end(s.uuid::Int, Ptr{Cvoid}(s.id)::Ptr{Cvoid}, s.how::Cint)::Cvoid
    end
    lock(STREAMS_LOCK); delete!(STREAMS, s.id); unlock(STREAMS_LOCK)
    nothing
end

# ---- chunk sources
const SEQ = Threads.Atomic{Int}(0)
struct Src; fresh::Bool; seq::Int; body::Vector{UInt8}; len::Int; end
# A fresh chunk describes itself: response number, chunk index, then a fill
# byte derived from both, so a reader can tell any foreign byte.
function fresh_chunk(seq::Int, i::Int, len::Int)
    v = Vector{UInt8}(undef, len)
    fill!(v, ((seq * 31 + i) & 0xff) % UInt8)
    for k in 0:7; v[k+1] = ((seq >>> (8k)) & 0xff) % UInt8; end
    for k in 0:3; v[k+9] = ((i >>> (8k)) & 0xff) % UInt8; end
    return v
end
chunkof(src::Src, i::Int) = src.fresh ? fresh_chunk(src.seq, i, src.len) : src.body
const XCHUNK = Dict{Int,Vector{UInt8}}(); const XLOCK = ReentrantLock()
xbuf(n::Int) = lock(() -> get!(() -> fill(UInt8('x'), n), XCHUNK, n), XLOCK)

# ---- copying baseline, as in v8_stream
chunk(uuid::Int, c::Vector{UInt8}) = @ccall gc_safe=true LIB.shim_write_chunk(uuid::Int, c::Ptr{UInt8}, sizeof(c)::Csize_t)::Cssize_t
last_chunk(uuid::Int) = @ccall gc_safe=true LIB.shim_write_last(uuid::Int)::Cssize_t
const CORKBUF = IOBuffer(sizehint = 1 << 17)
function cork_flush(uuid::Int)
    n = position(CORKBUF)
    n > 0 && @ccall gc_safe=true LIB.shim_write_copy(uuid::Int, CORKBUF.data::Ptr{UInt8}, n::Csize_t)::Cssize_t
    seekstart(CORKBUF); nothing
end
function cork_chunk(uuid::Int, c::Vector{UInt8})
    print(CORKBUF, string(sizeof(c), base = 16), "\r\n"); write(CORKBUF, c); write(CORKBUF, "\r\n")
    position(CORKBUF) >= 65536 && cork_flush(uuid)
    nothing
end
old_begin(h) = @ccall gc_safe=true LIB.shim_stream_begin_old(h::Ptr{Cvoid})::Int

# ---- timers on the reactor, one per slow response. With several reactor
# threads a timer's ticks and its finish callback are not serialized, so each
# response carries its own lock and ends itself on its last tick.
mutable struct Slow
    const uuid::Int; const s::Union{Stream,Nothing}; const src::Src; const n::Int
    i::Int; finished::Bool
    const lock::Threads.SpinLock
end
Slow(uuid, s, src, n) = Slow(uuid, s, src, n, 0, false, Threads.SpinLock())
const SLOW = Dict{Int,Slow}(); const SLOW_LOCK = Threads.SpinLock(); const SLOW_SEQ = Threads.Atomic{Int}(0)
slow_get(id::Int) = (lock(SLOW_LOCK); t = get(SLOW, id, nothing); unlock(SLOW_LOCK); t)
function slow_tick(arg::Ptr{Cvoid})::Cvoid
    t = slow_get(Int(arg))
    t === nothing && return nothing
    lock(t.lock)
    if t.i < t.n
        c = chunkof(t.src, t.i); t.i += 1
        t.s === nothing ? chunk(t.uuid, c) : write(t.s, c)
        if t.i == t.n
            if t.s === nothing
                last_chunk(t.uuid)
                @ccall gc_safe=true LIB.http1_stream_end(t.uuid::Int)::Cvoid
            else
                close(t.s)
            end
            t.finished = true
        end
    end
    unlock(t.lock)
    nothing
end
function slow_done(arg::Ptr{Cvoid})::Cvoid
    t = slow_get(Int(arg))
    t === nothing && return nothing
    # A tick may still be running or queued behind this call.
    lock(t.lock); fin = t.finished; unlock(t.lock)
    if fin
        lock(SLOW_LOCK); delete!(SLOW, Int(arg)); unlock(SLOW_LOCK)
    else
        @ccall gc_safe=true LIB.fio_run_every(1::Csize_t, 1::Csize_t, C_NOOP[]::Ptr{Cvoid}, arg::Ptr{Cvoid}, C_SLOW_DONE[]::Ptr{Cvoid})::Cint
    end
    nothing
end
noop(::Ptr{Cvoid})::Cvoid = nothing
const C_SLOW_TICK = Ref{Ptr{Cvoid}}(); const C_SLOW_DONE = Ref{Ptr{Cvoid}}(); const C_NOOP = Ref{Ptr{Cvoid}}()
function slow_start(t::Slow)
    id = Threads.atomic_add!(SLOW_SEQ, 1) + 1
    lock(SLOW_LOCK); SLOW[id] = t; unlock(SLOW_LOCK)
    @ccall gc_safe=true LIB.fio_run_every(1::Csize_t, t.n::Csize_t, C_SLOW_TICK[]::Ptr{Cvoid}, Ptr{Cvoid}(id)::Ptr{Cvoid}, C_SLOW_DONE[]::Ptr{Cvoid})::Cint
end

function produce(s::Stream, n::Int, src::Src, delay::Bool)
    for i in 0:n-1
        delay && sleep(0.001)
        write(s, chunkof(src, i)) < 0 && break
        delay && s.selfflush && flush(s)
    end
    close(s)
end

function stream(h::Ptr{Cvoid}, kind::AbstractString, n::Int, src::Src)
    if kind == "r"
        s = open_stream(h, 0)
        for i in 0:n-1; write(s, chunkof(src, i)); end
        close(s)
    elseif kind == "t1" || kind == "t2" || kind == "t1slow" || kind == "t2slow" || kind == "tnb"
        s = open_stream(h, 2, kind == "t2" || kind == "t2slow", kind == "tnb" ? typemax(Int) : HIGH)
        Threads.@spawn produce($s, $n, $src, $(endswith(kind, "slow")))
    elseif kind == "rslow"
        slow_start(Slow(0, open_stream(h, 1), src, n))
    elseif kind == "slowkeep"
        slow_start(Slow(old_begin(h), nothing, src, n))
    elseif kind == "stock"
        closing = Ref{Cint}(0)
        uuid = @ccall gc_safe=true LIB.shim_stream_stock(h::Ptr{Cvoid}, closing::Ref{Cint})::Int
        for i in 0:n-1; chunk(uuid, chunkof(src, i)); end
        last_chunk(uuid)
        closing[] != 0 && @ccall gc_safe=true LIB.fio_close(uuid::Int)::Cvoid
    elseif kind == "keep"
        uuid = old_begin(h)
        for i in 0:n-1; chunk(uuid, chunkof(src, i)); end
        last_chunk(uuid)
        @ccall gc_safe=true LIB.http1_stream_end_now(uuid::Int)::Cvoid
    elseif kind == "cork"
        uuid = old_begin(h)
        for i in 0:n-1; cork_chunk(uuid, chunkof(src, i)); end
        write(CORKBUF, "0\r\n\r\n"); cork_flush(uuid)
        @ccall gc_safe=true LIB.http1_stream_end_now(uuid::Int)::Cvoid
    else
        @ccall gc_safe=true LIB.http_send_error(h::Ptr{Cvoid}, 404::Csize_t)::Cint
    end
    nothing
end

# ---- routes
const TEXT = ["content-type" => "text/plain"]
const OCTET = ["content-type" => "application/octet-stream"]
const JSONH = ["content-type" => "application/json"]
const HDR5 = [string("x-custom-header-", lpad(i, 2, '0')) => string("value-", lpad(i, 2, '0'), "-abcdefghijklmnop") for i in 1:5]
const WMODE = Dict("copy" => 0, "two" => 1, "gather" => 2)
const GCS = Threads.Atomic{Int}(0)
pattern(n::Int) = UInt8[((i * 7 + (i >>> 10)) & 0xff) % UInt8 for i in 0:n-1]
const PATTERNS = Dict{Int,Vector{UInt8}}()
pbuf(n::Int) = lock(() -> get!(() -> pattern(n), PATTERNS, n), XLOCK)
function fresh_body(n::Int)
    seq = Threads.atomic_add!(SEQ, 1) + 1
    v = Vector{UInt8}(undef, n)
    fill!(v, seq % UInt8)
    for k in 0:min(7, n - 1); v[k+1] = ((seq >>> (8k)) & 0xff) % UInt8; end
    return v
end

function on_request(h::Ptr{Cvoid})::Cvoid
    pr = Ref(Slice(C_NULL, 0)); qr = Ref(Slice(C_NULL, 0))
    ccall((:shim_req, LIB), Cvoid, (Ptr{Cvoid}, Ref{Slice}, Ref{Slice}), h, pr, qr)
    path = unsafe_string(pr[].ptr, pr[].len)
    if startswith(path, "/w/")
        p = split(path, '/')
        respond(h, 200, TEXT, xbuf(parse(Int, p[4])), WMODE[p[3]])
    elseif startswith(path, "/s/")
        p = split(path, '/')
        stream(h, p[3], parse(Int, p[4]), Src(false, 0, xbuf(parse(Int, p[5]) * 1024), 0))
    elseif startswith(path, "/p/")
        p = split(path, '/')
        stream(h, p[3], parse(Int, p[4]), Src(true, Threads.atomic_add!(SEQ, 1) + 1, UInt8[], parse(Int, p[5])))
    elseif startswith(path, "/wp/")
        p = split(path, '/')
        respond(h, 200, OCTET, pbuf(parse(Int, p[4])), WMODE[p[3]])
    elseif startswith(path, "/wf/")
        p = split(path, '/')
        respond(h, 200, OCTET, fresh_body(parse(Int, p[4])), WMODE[p[3]])
    elseif path == "/ping"
        respond(h, 200, TEXT, "ok")
    elseif path == "/hdr/5"
        respond(h, 200, HDR5, "ok")
    elseif path == "/stats"
        lock(ROOT_LOCK); live = length(ROOTS); unlock(ROOT_LOCK)
        lock(STREAMS_LOCK); ns = length(STREAMS); unlock(STREAMS_LOCK)
        respond(h, 200, JSONH, """{"live":$live,"streams":$ns,"rooted":$(N_ROOTED[]),"released":$(N_RELEASED[]),"miss":$(N_MISS[]),"waits":$(N_WAITS[]),"max_pending":$(MAX_PENDING[]),"gcs":$(GCS[]),"wakes":$(ccall((:shim_wakes, LIB), Culong, ())),"rss_mb":$(Sys.maxrss() >> 20)}""")
    elseif path == "/reset"
        MAX_PENDING[] = 0; N_WAITS[] = 0
        respond(h, 200, TEXT, "ok")
    else
        @ccall gc_safe=true LIB.http_send_error(h::Ptr{Cvoid}, 404::Csize_t)::Cint
    end
    nothing
end

function main()
    C_DEALLOC[] = @cfunction(on_dealloc, Cvoid, (Ptr{Cvoid},))
    C_GONE[] = @cfunction(on_gone, Cvoid, (Ptr{Cvoid},))
    C_DRAIN[] = @cfunction(on_drain, Cvoid, (Int, Ptr{Cvoid}))
    C_SLOW_TICK[] = @cfunction(slow_tick, Cvoid, (Ptr{Cvoid},)); C_SLOW_DONE[] = @cfunction(slow_done, Cvoid, (Ptr{Cvoid},)); C_NOOP[] = @cfunction(noop, Cvoid, (Ptr{Cvoid},))
    ccall((:shim_gather_set, LIB), Cvoid, (Cint,), get(ENV, "GATHER", "1") == "1")
    ccall((:shim_wake_init, LIB), Cint, ())
    tls = C_NULL
    if TLS
        tls = ccall((:fio_tls_new, LIB), Ptr{Cvoid}, (Cstring, Cstring, Cstring, Ptr{Cchar}), "localhost", joinpath(HERE, "cert.pem"), joinpath(HERE, "key.pem"), C_NULL)
    end
    s = HttpSettings(@cfunction(on_request, Cvoid, (Ptr{Cvoid},)), C_NULL, C_NULL, C_NULL, C_NULL, C_NULL,
                     0, 0, 0, 0, tls, 0, 0, 0, 0, 0, 0, 0, 0)
    r = ccall((:http_listen, LIB), Int, (Cstring, Cstring, HttpSettings), PORT, get(ARGS, 2, "127.0.0.1"), s)
    r < 0 && error("http_listen failed")
    if get(ENV, "GCLOOP", "0") == "1"
        Threads.@spawn while true
            junk = [fill(0xee, rand(1:300_000)) for _ in 1:16]
            GC.gc()
            Threads.atomic_add!(GCS, 1)
            junk = nothing
            yield()
        end
    end
    println(stderr, "listening on $PORT pid=$(getpid()) julia threads=$(Threads.nthreads()) reactor threads=$RTHREADS gather=$(get(ENV, "GATHER", "1")) tls=$TLS")
    wait(Threads.@spawn @ccall gc_safe=true LIB.fio_start(FioStartArgs(RTHREADS, 1)::FioStartArgs)::Cvoid)
end
main()
