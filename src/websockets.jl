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

One WebSocket connection. Facil creates it when a handler returns
[`websocket`](@ref) and passes it to every callback.

| Call | Effect |
|:--|:--|
| [`send(ws, msg)`](@ref send) | send a text (`String`) or binary (`Vector{UInt8}`) message |
| [`close(ws; code, reason)`](@ref Base.close(::WebSocket)) | start the closing handshake |
| `isopen(ws)` | `true` between `on_open` and the close |
| [`subscribe(ws, channel)`](@ref subscribe(::WebSocket, ::AbstractString)) | forward a pub/sub channel to this client |
| [`Facil.pending_bytes(ws)`](@ref) | bytes queued for the client and not yet sent |
| `ws.data` | a field of type `Any` for your own per-connection state, initially `nothing` |

`send`, `close`, `subscribe` and `unsubscribe` are safe from any task or
thread, so you may keep a `WebSocket` (in a `Dict`, a `Set` behind a lock) and
use it outside its callbacks. Drop it in `on_close`.
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
    Facil.WebSocketUpgrade

What [`websocket`](@ref) returns. It has no use except being returned from a
handler, which makes Facil perform the upgrade. Each one can be returned once.
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
    Facil.is_upgrade(req::Request) -> Bool

Whether `req` asks to switch to the WebSocket protocol (its `upgrade` header
names `websocket`).

Use it to serve a normal response and a WebSocket on the same path, or to
answer non-WebSocket requests with a helpful status instead of the `400` that
returning [`websocket`](@ref) for them produces.

# Examples
```jldoctest
julia> using Facil

julia> Facil.is_upgrade(Request(Methods.GET, "/chat"; headers = ["upgrade" => "websocket"]))
true

julia> Facil.is_upgrade(Request(Methods.GET, "/chat"))
false
```
"""
function is_upgrade(req::Request)
    v = get(headers(req), header.UPGRADE, nothing)
    v === nothing && return false
    occursin("websocket", lowercase(as_str(v)))
end

"""
    websocket(req; on_open, on_message, on_close, on_ready, on_shutdown,
              max_message_size = 1 MiB, deflate = false, utf8_check = true,
              spawn = false, borrow = false, subprotocol = nothing) -> Facil.WebSocketUpgrade

Accept a WebSocket upgrade. Return the result from your handler.

# Arguments
- `req`: the upgrade request. If it is not a valid WebSocket upgrade the client
  gets a `400` and no callback runs; test with [`Facil.is_upgrade`](@ref) first
  to answer something else.

# Callbacks
All are optional keywords.
- `on_open(ws)`: once, when the connection is ready and before any message.
- `on_message(ws, msg)`: for each message. `msg` is a `String` for a text
  message and a `Vector{UInt8}` for a binary one. Fragmented messages arrive
  whole.
- `on_close(ws)`: once, after the connection is gone. `send` no longer works.
- `on_ready(ws)`: when output that had been queued has all been sent; use it to
  resume producing after [`Facil.pending_bytes`](@ref) grew.
- `on_shutdown(ws)`: when the connection's server is closed or drained
  ([`close(server)`](@ref Base.close(::Server)), SIGTERM under
  [`serve`](@ref)), or the process exits, while the connection is open, just
  before Facil sends a `1001` close. The last chance to send.

# Keywords
- `spawn::Bool = false`: where callbacks run.
  - `false`: on the reactor thread, in order. They must not block. An echo
    costs no task switch.
  - `true`: on Julia tasks, still one at a time and in order for each
    connection, so they may block. Reading from this client pauses while more
    than 16 MiB of its messages wait to be handled.
- `max_message_size::Integer = 1 MiB`: a larger message closes the connection
  with code `1009`.
- `utf8_check::Bool = true`: a text message that is not valid UTF-8 closes the
  connection with code `1007`. `false` skips the check.
- `deflate = false`: `true` accepts the permessage-deflate extension (without
  context takeover) when the client offers it. An integer `1` to `9` does the
  same and sets the compression level, process-wide. Messages under 128 bytes,
  and those that do not shrink, are sent uncompressed.
- `borrow::Bool = false`: with `spawn = false`, pass each binary message as a
  view of facil.io's buffer instead of a copy. The vector is valid only until
  `on_message` returns; `copy` it to keep it.
- `subprotocol::Union{Nothing,AbstractString} = nothing`: sent back as
  `Sec-WebSocket-Protocol`. Choose it from the request's header of that name.

# Returns
A [`Facil.WebSocketUpgrade`](@ref) for the handler to return.

# Throws
- `ArgumentError` if `max_message_size` is not positive, a `deflate` level is
  outside `1:9`, or `subprotocol` contains a line break.

# Notes
- An exception in a callback is logged; the connection stays open.
- Pings from the client are answered by facil.io, and an idle connection is
  pinged every 40 seconds. The server's `timeout` keyword does not change that.
- To send one message to many clients, use [`subscribe`](@ref) and
  [`publish`](@ref) instead of a loop over `send`.

# Examples
An echo server. A WebSocket needs a WebSocket client, so this example only
builds the upgrade; `docs/examples/ws_echo.jl` is the complete program, which
the documentation build runs against a client.

```jldoctest
julia> using Facil

julia> function app(req)
           Facil.is_upgrade(req) || return Response(StatusCodes.UPGRADE_REQUIRED, "WebSocket only")
           websocket(req;
                     on_open = ws -> send(ws, "welcome"),
                     on_message = (ws, msg) -> send(ws, msg))
       end;

julia> req = Request(Methods.GET, "/"; headers = ["upgrade" => "websocket"]);

julia> app(req) isa Facil.WebSocketUpgrade
true

julia> status(app(Request(Methods.GET, "/")))
StatusCodes.UPGRADE_REQUIRED
```

See the [WebSockets guide](@ref websockets-guide).
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
    lock_sigatomic(LIVE_WS_LOCK)
    LIVE_WS[key] = ws
    unlock_sigatomic(LIVE_WS_LOCK)
    sp = something(u.subprotocol, "")
    GC.@preserve sp @ccall LIBFJL.fjl_ws_upgrade(h::Ptr{Cvoid}, key::Ptr{Cvoid}, u.flags::Cuint,
                                                 u.max_message_size::Csize_t, pointer(sp)::Ptr{UInt8},
                                                 sizeof(sp)::Csize_t)::Cint
    nothing
end

"""
    send(ws::WebSocket, msg) -> Bool

Send `msg` to the client as one WebSocket message.

# Arguments
- `msg`: a `String` (or any `AbstractString`) is sent as a text message, a
  `Vector{UInt8}` (or any byte vector) as a binary message.

# Returns
`true` if the message was queued; `false`, sending nothing, if the connection
is closing or closed. It does not throw for a closed connection.

# Notes
- Safe from any task or thread, inside or outside the callbacks.
- It never blocks. Bytes the socket does not take at once are copied and
  queued, so a client that does not read makes memory grow: watch
  [`Facil.pending_bytes`](@ref) or `on_ready` when you send faster than
  clients may read.
- A `String` is not checked for valid UTF-8.

See [`websocket`](@ref) for an example.
"""
function send(ws::WebSocket, msg::Union{String,Vector{UInt8}})
    (@atomic ws.state) == WS_OPEN || return false
    # GC-safe: the call can spin on a connection lock that a callback holds,
    # and that callback may be waiting for a collection.
    uuid, n, text = ws.uuid, sizeof(msg), Cint(msg isa String)
    r = GC.@preserve msg begin
        p = Ptr{UInt8}(pointer(msg))
        @gcsafe_ccall LIBFJL.fjl_ws_send(uuid::Int, p::Ptr{UInt8}, n::Csize_t, text::Cint)::Cint
    end
    r == 0
end
send(ws::WebSocket, msg::AbstractString) = send(ws, String(msg))
send(ws::WebSocket, msg::AbstractVector{UInt8}) = send(ws, Vector{UInt8}(msg))

"""
    close(ws::WebSocket; code = 1000, reason = "")

Start the WebSocket closing handshake.

# Keywords
- `code::Integer = 1000`: the close code: `1000` (normal), `1001` to `1014`, or
  an application code `3000` to `4999`.
- `reason::AbstractString = ""`: text sent with it; truncated to 123 bytes.

Returns `nothing` at once. The socket closes when the client answers, or after
3 seconds. `on_close` runs after that. Safe from any thread; does nothing on a
connection that is already closing.

# Throws
- `ArgumentError` for a code outside those ranges.
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
    subscribe(ws::WebSocket, channel; binary = nothing) -> Bool

Forward every message published to `channel` to this WebSocket client.

No Julia code runs per message: facil.io builds the frame once and shares it
among all subscribers of the channel, which is what makes broadcasting to
thousands of clients cheap.

# Arguments
- `channel::AbstractString`: the channel name; any string.
- `binary = nothing`: `true` sends binary messages, `false` text. By default a
  message is sent as text when it is valid UTF-8 and as binary otherwise.

# Returns
`true` if subscribed, `false` if the connection is not open (before `on_open`
or after the close).

# Notes
- Call it in `on_open` or later. Subscribing twice to one channel is a no-op.
- The subscription ends with the connection or with [`unsubscribe`](@ref).
- A client that reads too slowly is handled by [`Facil.slow_subscribers!`](@ref).

See [`publish`](@ref) and the [pub/sub guide](@ref pubsub-guide).
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
    unsubscribe(ws::WebSocket, channel) -> Bool

Stop forwarding `channel` to this WebSocket client. Returns `false` if the
connection is not open. Unsubscribing from a channel it is not subscribed to
does nothing.
"""
function unsubscribe(ws::WebSocket, channel::AbstractString)
    ch = String(channel)
    (@atomic ws.state) == WS_OPEN || return false
    r = GC.@preserve ch @ccall LIBFJL.fjl_ws_unsubscribe(ws.uuid::Int, pointer(ch)::Ptr{UInt8}, sizeof(ch)::Csize_t)::Cint
    r == 0
end

"""
    Facil.pending_bytes(ws::WebSocket) -> Int

The number of bytes queued for this client that the socket has not taken yet;
`0` for a closed connection.

`send` never blocks, so this is how you see a client falling behind. A common
pattern: stop producing when it passes a threshold and continue in `on_ready`.
"""
pending_bytes(ws::WebSocket) = isopen(ws) ? Int(@ccall LIBFJL.fjl_ws_pending(ws.uuid::Int)::Csize_t) : 0

const SLOW_POLICIES = (ignore = 0, close = 1, drop_newest = 2, drop_oldest = 3)

"""
    Facil.slow_subscribers!(; limit, policy = :close)

Decide what a broadcast does with a WebSocket subscriber that is not reading.

# Keywords
- `limit::Integer`: a subscriber with more than this many unsent bytes queued
  counts as slow. `0` disables the check (the default state): queues grow
  without bound.
- `policy::Symbol = :close`: what happens to a slow subscriber when the next
  message is published:
  - `:close`: its connection is closed;
  - `:drop_newest`: the new message is skipped for it;
  - `:drop_oldest`: its oldest unsent broadcasts are discarded to make room;
  - `:ignore`: nothing; the event is only counted.

# Throws
- `ArgumentError` for a negative `limit` or an unknown `policy`.

# Notes
Process-wide, for every channel and server. It applies to messages delivered
through [`subscribe(ws, channel)`](@ref subscribe(::WebSocket, ::AbstractString)),
not to [`send`](@ref). [`Facil.slow_subscriber_stats`](@ref) counts what happened.

# Examples
```jldoctest
julia> using Facil

julia> Facil.slow_subscribers!(; limit = 4 * 1024 * 1024, policy = :drop_oldest)

julia> Facil.slow_subscribers!(; limit = 0)
```
"""
function slow_subscribers!(; limit::Integer, policy::Symbol = :close)
    limit >= 0 || throw(ArgumentError("limit must not be negative"))
    haskey(SLOW_POLICIES, policy) || throw(ArgumentError("policy must be one of $(keys(SLOW_POLICIES))"))
    @ccall LIBFJL.websocket_slow_subscriber_set(limit::Csize_t, Cint(SLOW_POLICIES[policy])::Cint, C_NULL::Ptr{Cvoid})::Cvoid
    nothing
end

"""
    Facil.slow_subscriber_stats() -> NamedTuple

Counters for [`Facil.slow_subscribers!`](@ref) since the process started:
`(dropped, closed, events)`: messages dropped, connections closed, and the
number of times a subscriber was found over the limit.

# Examples
```jldoctest
julia> using Facil

julia> keys(Facil.slow_subscriber_stats())
(:dropped, :closed, :events)
```
"""
function slow_subscriber_stats()
    d, c, e = Ref{Csize_t}(0), Ref{Csize_t}(0), Ref{Csize_t}(0)
    @ccall LIBFJL.websocket_slow_subscriber_stats(d::Ref{Csize_t}, c::Ref{Csize_t}, e::Ref{Csize_t})::Cvoid
    (dropped = Int(d[]), closed = Int(c[]), events = Int(e[]))
end

"""
    Facil.open_websockets() -> Int

The number of WebSocket connections that have been upgraded and not yet
closed, across every server.
"""
open_websockets() = (lock_sigatomic(LIVE_WS_LOCK); n = length(LIVE_WS); unlock_sigatomic(LIVE_WS_LOCK); n)

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
    lock_sigatomic(q.lock)
    push!(q.items, ev)
    q.bytes += n
    start = !q.running
    start && (q.running = true)
    pause = !q.paused && q.bytes > WS_QUEUE_HIGH && !(ev isa WSClose)
    pause && (q.paused = true)
    unlock_sigatomic(q.lock)
    pause && @ccall LIBFJL.fjl_ws_read_pause(ws.uuid::Int, 1::Cint)::Cint
    start && Threads.@spawn drain_queue!($ws, $q)
    nothing
end

function drain_queue!(ws::WebSocket, q::WSQueue)
    while true
        lock_sigatomic(q.lock)
        if isempty(q.items)
            q.running = false
            unlock_sigatomic(q.lock)
            return
        end
        ev = popfirst!(q.items)
        q.bytes -= event_bytes(ev)
        resume = q.paused && q.bytes < WS_QUEUE_LOW
        resume && (q.paused = false)
        unlock_sigatomic(q.lock)
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
        lock_sigatomic(LIVE_WS_LOCK)
        delete!(LIVE_WS, jl)
        unlock_sigatomic(LIVE_WS_LOCK)
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
    Facil.websocket_compressor!(codec::Symbol)

Choose the codec used for WebSocket permessage-deflate, process-wide.

- `:zlibng` (the default): zlib-ng compresses and libdeflate decompresses.
- `:zlib`: facil.io's built-in codec, which uses the system zlib.

Call it before serving. Throws `ArgumentError` for any other symbol. It only
matters for connections accepted with `websocket(...; deflate = true)`.
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
