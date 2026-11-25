import libdeflate_jll, ZlibNG_jll

# WebSockets. A connection is addressed by its uuid; facil.io owns and frees the
# socket object. Each WebSocket stays in LIVE_WS from the upgrade until facil.io
# reports the close, so the pointer handed to C is always valid.

const WS_PENDING, WS_OPEN, WS_CLOSED = 0, 1, 2

# Events queued for a connection whose callbacks run on Julia tasks.
struct WSOpen end
struct WSReady end
struct WSShutdown end
struct WSClose end

mutable struct WSQueue
    const lock::Threads.SpinLock
    items::Vector{Any}
    bytes::Int
    running::Bool
    paused::Bool
end
WSQueue() = WSQueue(Threads.SpinLock(), Any[], 0, false, false)

"""
    WebSocket

One WebSocket connection, passed to the callbacks given to [`websocket`](@ref).
[`send`](@ref) and `close(ws; code, reason)` work from any thread; `isopen(ws)`
tells whether messages can still be sent. `ws.data` is free for the application.
"""
mutable struct WebSocket
    const on_open::Any
    const on_message::Any
    const on_close::Any
    const on_ready::Any
    const on_shutdown::Any
    const queue::Union{Nothing,WSQueue}
    const borrow::Bool
    uuid::Int
    @atomic state::Int
    data::Any
end

"""
    WebSocketUpgrade

What [`websocket`](@ref) returns; a handler returns it to accept the upgrade.
"""
struct WebSocketUpgrade
    ws::WebSocket
    flags::UInt32
    max_message_size::Int
    subprotocol::Union{Nothing,String}
end

const LIVE_WS = Dict{Ptr{Cvoid},WebSocket}()
const LIVE_WS_LOCK = Threads.SpinLock()
const WS_FLAG_DEFLATE, WS_FLAG_READY, WS_FLAG_SHUTDOWN, WS_FLAG_NO_UTF8 = 0x1, 0x2, 0x4, 0x8
const WS_QUEUE_HIGH = 16 * 1024 * 1024
const WS_QUEUE_LOW = 4 * 1024 * 1024
const WS_DEFLATE_LEVEL = Ref(1)

uuid(ws::WebSocket) = ws.uuid
Base.isopen(ws::WebSocket) = (@atomic ws.state) == WS_OPEN

function Base.show(io::IO, ws::WebSocket)
    st = ("pending", "open", "closed")[(@atomic ws.state)+1]
    print(io, "Facil.WebSocket(", ws.uuid, ", ", st, ")")
end

"""
    is_upgrade(req) -> Bool

True when `req` asks to switch to the WebSocket protocol.
"""
function is_upgrade(req::Request)
    v = get(headers(req), header.UPGRADE, nothing)
    v === nothing && return false
    occursin("websocket", lowercase(as_str(v)))
end

"""
    websocket(req; on_open, on_message, on_close, on_ready, on_shutdown,
              max_message_size = 1 MiB, deflate = false, utf8_check = true,
              spawn = false, borrow = false, subprotocol = nothing) -> WebSocketUpgrade

Accepts a WebSocket upgrade; return the result from the handler. A request that
is not a valid upgrade gets a 400 and no callback runs.

Callbacks, all optional:
- `on_open(ws)` once, before any message;
- `on_message(ws, msg)`: `msg` is a `String` for a text message, a `Vector{UInt8}`
  for a binary one;
- `on_close(ws)` once, after the connection is gone;
- `on_ready(ws)` when queued output has drained;
- `on_shutdown(ws)` when the server stops (a 1001 close follows).

By default callbacks run on the reactor thread, in order, and must not block:
an echo costs no task switch. `borrow = true` passes a binary message as a view
of facil.io's buffer instead of a copy: it is valid only until `on_message`
returns and must not be kept (`copy` it to keep it). `spawn = true` runs callbacks on Julia tasks instead,
still one at a time and in order per connection; reading from the peer pauses
while more than 16 MiB of messages wait.

Messages over `max_message_size` bytes close the connection with 1009. Text
messages that are not valid UTF-8 close it with 1007 unless `utf8_check = false`.
`deflate = true` accepts permessage-deflate (without context takeover) when
the client offers it; an integer also sets the compression level, process-wide
(1–9; see
[`Facil.websocket_compressor!`](@ref)). Messages under 128 bytes, and those that
do not shrink, are sent uncompressed.
`subprotocol` is sent back as `Sec-WebSocket-Protocol`.
"""
function websocket(req::Request; on_open = nothing, on_message = nothing, on_close = nothing,
                   on_ready = nothing, on_shutdown = nothing, max_message_size::Integer = 1024 * 1024,
                   deflate::Union{Bool,Integer,Nothing} = false, utf8_check::Bool = true,
                   spawn::Bool = false, borrow::Bool = false,
                   subprotocol::Union{Nothing,AbstractString} = nothing)
    max_message_size > 0 || throw(ArgumentError("max_message_size must be positive"))
    flags = UInt32(0)
    if deflate isa Integer && !(deflate isa Bool)
        1 <= deflate <= 9 || throw(ArgumentError("deflate level must be between 1 and 9"))
        set_deflate_level(Int(deflate))
        flags |= WS_FLAG_DEFLATE
    elseif deflate === true
        flags |= WS_FLAG_DEFLATE
    end
    on_ready === nothing || (flags |= WS_FLAG_READY)
    on_shutdown === nothing || (flags |= WS_FLAG_SHUTDOWN)
    utf8_check || (flags |= WS_FLAG_NO_UTF8)
    sp = subprotocol === nothing ? nothing : String(subprotocol)
    sp === nothing || (occursin('\r', sp) || occursin('\n', sp)) && throw(ArgumentError("invalid subprotocol"))
    ws = WebSocket(on_open, on_message, on_close, on_ready, on_shutdown, spawn ? WSQueue() : nothing,
                   borrow && !spawn, -1, WS_PENDING, nothing)
    WebSocketUpgrade(ws, flags, Int(max_message_size), sp)
end

function set_deflate_level(level::Int)
    WS_DEFLATE_LEVEL[] == level && return nothing
    WS_DEFLATE_LEVEL[] = level
    @ccall LIBFJL.fjl_ws_deflate_config(level::Cint, 128::Csize_t)::Cvoid
    nothing
end

function respond(h::Ptr{Cvoid}, u::WebSocketUpgrade)
    ws = u.ws
    (@atomic ws.state) == WS_PENDING && ws.uuid == -1 || throw(ArgumentError("a WebSocketUpgrade can be returned only once"))
    key = pointer_from_objref(ws)
    lock(LIVE_WS_LOCK)
    LIVE_WS[key] = ws
    unlock(LIVE_WS_LOCK)
    sp = something(u.subprotocol, "")
    GC.@preserve sp @ccall LIBFJL.fjl_ws_upgrade(h::Ptr{Cvoid}, key::Ptr{Cvoid}, u.flags::Cuint,
                                                 u.max_message_size::Csize_t, pointer(sp)::Ptr{UInt8},
                                                 sizeof(sp)::Csize_t)::Cint
    nothing
end

"""
    send(ws::WebSocket, msg) -> Bool

Sends `msg` as one message: text for a `String`, binary for a `Vector{UInt8}`.
Works from any thread; the bytes the socket does not take at once are copied.
Returns `false` (and sends nothing) once the connection is closing or closed.
"""
function send(ws::WebSocket, msg::Union{String,Vector{UInt8}})
    (@atomic ws.state) == WS_OPEN || return false
    r = GC.@preserve msg @ccall LIBFJL.fjl_ws_send(ws.uuid::Int, pointer(msg)::Ptr{UInt8}, sizeof(msg)::Csize_t,
                                                   (msg isa String)::Cint)::Cint
    r == 0
end
send(ws::WebSocket, msg::AbstractString) = send(ws, String(msg))
send(ws::WebSocket, msg::AbstractVector{UInt8}) = send(ws, Vector{UInt8}(msg))

"""
    close(ws::WebSocket; code = 1000, reason = "")

Starts the closing handshake; the socket closes when the peer answers, or after
3 seconds. Works from any thread; a no-op once closed. `on_close` runs later.
"""
function Base.close(ws::WebSocket; code::Integer = 1000, reason::AbstractString = "")
    (code == 1000 || 3000 <= code <= 4999 || 1001 <= code <= 1014) ||
        throw(ArgumentError("invalid close code $code"))
    r = String(reason)
    (@atomic ws.state) == WS_OPEN || return nothing
    GC.@preserve r @ccall LIBFJL.fjl_ws_close(ws.uuid::Int, Cint(code)::Cint, pointer(r)::Ptr{UInt8},
                                              min(sizeof(r), 123)::Csize_t)::Cint
    nothing
end

"""
    subscribe(ws::WebSocket, channel; binary = nothing)

Forwards every message published to `channel` straight to the client, without
running Julia code per message: the frame is built once and shared by every
subscriber. `binary = true/false` forces the opcode; by default a message is
sent as text when it is valid UTF-8. Subscribing twice is a no-op; the
subscription ends with the connection or with [`unsubscribe`](@ref).
"""
function subscribe(ws::WebSocket, channel::AbstractString; binary::Union{Nothing,Bool} = nothing)
    ch = String(channel)
    mode = binary === nothing ? 0 : binary ? 2 : 1
    (@atomic ws.state) == WS_OPEN || return false
    r = GC.@preserve ch @ccall LIBFJL.fjl_ws_subscribe(ws.uuid::Int, pointer(ch)::Ptr{UInt8}, sizeof(ch)::Csize_t,
                                                       Cint(mode)::Cint)::Cint
    r == 0
end

"""
    unsubscribe(ws::WebSocket, channel)

Stops forwarding `channel` to `ws`.
"""
function unsubscribe(ws::WebSocket, channel::AbstractString)
    ch = String(channel)
    (@atomic ws.state) == WS_OPEN || return false
    r = GC.@preserve ch @ccall LIBFJL.fjl_ws_unsubscribe(ws.uuid::Int, pointer(ch)::Ptr{UInt8}, sizeof(ch)::Csize_t)::Cint
    r == 0
end

"""
    Facil.pending_bytes(ws::WebSocket) -> Int

Bytes queued for the client and not yet taken by the socket.
"""
pending_bytes(ws::WebSocket) = isopen(ws) ? Int(@ccall LIBFJL.fjl_ws_pending(ws.uuid::Int)::Csize_t) : 0

const SLOW_POLICIES = (ignore = 0, close = 1, drop_newest = 2, drop_oldest = 3)

"""
    Facil.slow_subscribers!(; limit, policy = :close)

What a [`subscribe`](@ref)d broadcast does with a client that has more than
`limit` unsent bytes (0 disables): `:close` it, `:drop_newest` (skip the new
message for it), `:drop_oldest` (discard its oldest unsent broadcasts) or
`:ignore`. Process-wide. `Facil.slow_subscriber_stats()` counts what happened.
"""
function slow_subscribers!(; limit::Integer, policy::Symbol = :close)
    limit >= 0 || throw(ArgumentError("limit must not be negative"))
    haskey(SLOW_POLICIES, policy) || throw(ArgumentError("policy must be one of $(keys(SLOW_POLICIES))"))
    @ccall LIBFJL.websocket_slow_subscriber_set(limit::Csize_t, Cint(SLOW_POLICIES[policy])::Cint, C_NULL::Ptr{Cvoid})::Cvoid
    nothing
end

function slow_subscriber_stats()
    d, c, e = Ref{Csize_t}(0), Ref{Csize_t}(0), Ref{Csize_t}(0)
    @ccall LIBFJL.websocket_slow_subscriber_stats(d::Ref{Csize_t}, c::Ref{Csize_t}, e::Ref{Csize_t})::Cvoid
    (dropped = Int(d[]), closed = Int(c[]), events = Int(e[]))
end

"""
    Facil.open_websockets() -> Int

WebSocket connections upgraded and not yet closed.
"""
open_websockets() = (lock(LIVE_WS_LOCK); n = length(LIVE_WS); unlock(LIVE_WS_LOCK); n)

# ---- callbacks from the reactor ----

@inline ws_of(jl::Ptr{Cvoid}) = unsafe_pointer_to_objref(jl)::WebSocket

function run_event(ws::WebSocket, ev)
    try
        if ev isa WSOpen
            ws.on_open === nothing || ws.on_open(ws)
        elseif ev isa WSClose
            ws.on_close === nothing || ws.on_close(ws)
        elseif ev isa WSReady
            ws.on_ready === nothing || ws.on_ready(ws)
        elseif ev isa WSShutdown
            ws.on_shutdown === nothing || ws.on_shutdown(ws)
        else
            ws.on_message === nothing || ws.on_message(ws, ev)
        end
    catch e
        log_error("a WebSocket callback", e, catch_backtrace())
    end
    nothing
end

event_bytes(ev) = ev isa Union{String,Vector{UInt8}} ? sizeof(ev) : 0

function enqueue!(ws::WebSocket, q::WSQueue, ev)
    n = event_bytes(ev)
    lock(q.lock)
    push!(q.items, ev)
    q.bytes += n
    start = !q.running
    start && (q.running = true)
    pause = !q.paused && q.bytes > WS_QUEUE_HIGH && !(ev isa WSClose)
    pause && (q.paused = true)
    unlock(q.lock)
    pause && @ccall LIBFJL.fjl_ws_read_pause(ws.uuid::Int, 1::Cint)::Cint
    start && Threads.@spawn drain_queue!($ws, $q)
    nothing
end

function drain_queue!(ws::WebSocket, q::WSQueue)
    while true
        lock(q.lock)
        if isempty(q.items)
            q.running = false
            unlock(q.lock)
            return
        end
        ev = popfirst!(q.items)
        q.bytes -= event_bytes(ev)
        resume = q.paused && q.bytes < WS_QUEUE_LOW
        resume && (q.paused = false)
        unlock(q.lock)
        resume && @ccall LIBFJL.fjl_ws_read_pause(ws.uuid::Int, 0::Cint)::Cint
        run_event(ws, ev)
    end
end

@inline function dispatch(ws::WebSocket, ev)
    q = ws.queue
    q === nothing ? run_event(ws, ev) : enqueue!(ws, q, ev)
end

function ws_on_open(jl::Ptr{Cvoid}, uuid::Int)
    try
        ws = ws_of(jl)
        ws.uuid = uuid
        @atomic ws.state = WS_OPEN
        dispatch(ws, WSOpen())
    catch e
        callback_error("WebSocket on_open", e, catch_backtrace())
    end
    nothing
end

function ws_on_message(jl::Ptr{Cvoid}, ::Int, data::Ptr{UInt8}, len::Csize_t, is_text::Cint)
    try
        ws = ws_of(jl)
        if is_text != 0
            dispatch(ws, unsafe_string(data, len))
        elseif ws.borrow
            run_event(ws, unsafe_wrap(Array, data, Int(len)))
        else
            v = Vector{UInt8}(undef, len)
            len > 0 && unsafe_copyto!(pointer(v), data, len)
            dispatch(ws, v)
        end
    catch e
        callback_error("WebSocket on_message", e, catch_backtrace())
    end
    nothing
end

function ws_on_ready(jl::Ptr{Cvoid}, ::Int)
    try
        dispatch(ws_of(jl), WSReady())
    catch e
        callback_error("WebSocket on_ready", e, catch_backtrace())
    end
    nothing
end

function ws_on_shutdown(jl::Ptr{Cvoid}, ::Int)
    try
        dispatch(ws_of(jl), WSShutdown())
    catch e
        callback_error("WebSocket on_shutdown", e, catch_backtrace())
    end
    nothing
end

function ws_on_close(jl::Ptr{Cvoid}, ::Int, opened::Cint)
    try
        ws = ws_of(jl)
        @atomic ws.state = WS_CLOSED
        lock(LIVE_WS_LOCK)
        delete!(LIVE_WS, jl)
        unlock(LIVE_WS_LOCK)
        opened != 0 && dispatch(ws, WSClose())
    catch e
        callback_error("WebSocket on_close", e, catch_backtrace())
    end
    nothing
end

struct WSCallbacks
    on_open::Ptr{Cvoid}
    on_message::Ptr{Cvoid}
    on_ready::Ptr{Cvoid}
    on_shutdown::Ptr{Cvoid}
    on_close::Ptr{Cvoid}
end

const WS_CODEC = Ref(:zlibng)

"""
    Facil.websocket_compressor!(codec)

Codec for permessage-deflate, process-wide: `:zlibng` (the default: zlib-ng
compresses, libdeflate decompresses) or `:zlib` (facil.io's own). Set it before
serving.
"""
function websocket_compressor!(codec::Symbol)
    codec in (:zlibng, :zlib) || throw(ArgumentError("codec must be :zlibng or :zlib"))
    WS_CODEC[] = codec
    if codec === :zlibng
        z = Libdl.dlopen(ZlibNG_jll.libzng)
        d = Libdl.dlopen(libdeflate_jll.libdeflate)
        @ccall LIBFJL.fjl_ws_codec(Libdl.dlsym(z, :zng_deflateInit2)::Ptr{Cvoid}, Libdl.dlsym(z, :zng_deflate)::Ptr{Cvoid},
                                   Libdl.dlsym(z, :zng_deflateReset)::Ptr{Cvoid}, Libdl.dlsym(z, :zng_deflateEnd)::Ptr{Cvoid},
                                   Libdl.dlsym(d, :libdeflate_alloc_decompressor)::Ptr{Cvoid},
                                   Libdl.dlsym(d, :libdeflate_deflate_decompress)::Ptr{Cvoid})::Cvoid
    else
        @ccall LIBFJL.fjl_ws_codec(C_NULL::Ptr{Cvoid}, C_NULL::Ptr{Cvoid}, C_NULL::Ptr{Cvoid}, C_NULL::Ptr{Cvoid},
                                   C_NULL::Ptr{Cvoid}, C_NULL::Ptr{Cvoid})::Cvoid
    end
    nothing
end

function init_websockets()
    cb = WSCallbacks(@cfunction(ws_on_open, Cvoid, (Ptr{Cvoid}, Int)),
                     @cfunction(ws_on_message, Cvoid, (Ptr{Cvoid}, Int, Ptr{UInt8}, Csize_t, Cint)),
                     @cfunction(ws_on_ready, Cvoid, (Ptr{Cvoid}, Int)),
                     @cfunction(ws_on_shutdown, Cvoid, (Ptr{Cvoid}, Int)),
                     @cfunction(ws_on_close, Cvoid, (Ptr{Cvoid}, Int, Cint)))
    @ccall LIBFJL.fjl_ws_init(Ref(cb)::Ptr{WSCallbacks})::Cvoid
    @ccall LIBFJL.fjl_ws_deflate_config(WS_DEFLATE_LEVEL[]::Cint, 128::Csize_t)::Cvoid
    websocket_compressor!(WS_CODEC[])
    init_pubsub()
    nothing
end

precompile(ws_on_open, (Ptr{Cvoid}, Int))
precompile(ws_on_message, (Ptr{Cvoid}, Int, Ptr{UInt8}, Csize_t, Cint))
precompile(ws_on_close, (Ptr{Cvoid}, Int, Cint))
precompile(respond, (Ptr{Cvoid}, WebSocketUpgrade))
precompile(send, (WebSocket, String))
precompile(send, (WebSocket, Vector{UInt8}))
