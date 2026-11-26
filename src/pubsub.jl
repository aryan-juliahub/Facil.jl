# Process-local pub/sub on facil.io's post office. A Subscription stays in
# LIVE_SUBS until facil.io reports it gone (on_unsubscribe).

"""
    Facil.Subscription

A subscription made by [`subscribe(f, channel)`](@ref subscribe(::Any, ::AbstractString)).

`isopen(sub)` is `true` until it is ended with [`unsubscribe(sub)`](@ref unsubscribe(::Facil.Subscription))
or `close(sub)`, which are the same. Keep the `Subscription` only if you intend
to end it; it stays active without a reference.
"""
mutable struct Subscription
    const channel::String
    const callback::Any
    const spawn::Bool
    ptr::Ptr{Cvoid}
    @atomic open::Bool
end

const LIVE_SUBS = Dict{Ptr{Cvoid},Subscription}()
const LIVE_SUBS_LOCK = Threads.SpinLock()

Base.isopen(s::Subscription) = @atomic s.open
Base.show(io::IO, s::Subscription) = print(io, "Facil.Subscription(", repr(s.channel), isopen(s) ? "" : ", closed", ")")

"""
    subscribe(f, channel; spawn = false) -> Facil.Subscription

Call `f(msg::String)` for every message published to `channel` in this process.

# Arguments
- `f`: the callback. It receives the message as a `String` (bytes published as
  a vector arrive as a `String` holding those bytes).
- `channel::AbstractString`: the channel name; matched exactly.

# Keywords
- `spawn::Bool = false`: `false` runs `f` on the reactor thread, one message at
  a time in publishing order; `f` must not block. `true` runs each call on its
  own Julia task: `f` may block, but calls can overlap and order is not kept.

# Returns
A [`Facil.Subscription`](@ref); pass it to [`unsubscribe`](@ref) to stop.

# Notes
- Starts the reactor if no server has yet.
- An exception in `f` is logged; the subscription stays active.
- To deliver a channel to WebSocket clients use
  [`subscribe(ws, channel)`](@ref subscribe(::WebSocket, ::AbstractString)), which
  runs no Julia code per message.

# Examples
```jldoctest
julia> using Facil

julia> inbox = Channel{String}(8);

julia> sub = subscribe(msg -> put!(inbox, msg), "news");

julia> publish("news", "hello")

julia> take!(inbox)
"hello"

julia> unsubscribe(sub)

julia> isopen(sub)
false
```
"""
function subscribe(f, channel::AbstractString; spawn::Bool = false)
    ensure_reactor()
    s = Subscription(String(channel), f, spawn, C_NULL, true)
    key = pointer_from_objref(s)
    lock(LIVE_SUBS_LOCK)
    LIVE_SUBS[key] = s
    unlock(LIVE_SUBS_LOCK)
    ch = s.channel
    p = GC.@preserve ch @ccall LIBFJL.fjl_ps_subscribe(pointer(ch)::Ptr{UInt8}, sizeof(ch)::Csize_t, key::Ptr{Cvoid})::Ptr{Cvoid}
    p == C_NULL && error("Facil: could not subscribe to $(repr(ch))")
    s.ptr = p
    s
end

"""
    unsubscribe(sub::Facil.Subscription)
    close(sub::Facil.Subscription)

End a subscription made with [`subscribe(f, channel)`](@ref subscribe(::Any, ::AbstractString)).
No call to its function starts afterwards. Returns `nothing`; ending it twice
does nothing.
"""
function unsubscribe(s::Subscription)
    _, ok = @atomicreplace s.open true => false
    ok && @ccall LIBFJL.fjl_ps_unsubscribe(s.ptr::Ptr{Cvoid})::Cvoid
    nothing
end
Base.close(s::Subscription) = unsubscribe(s)

"""
    publish(channel, msg)

Send `msg` to every subscriber of `channel` in this process.

# Arguments
- `channel::AbstractString`: the channel name.
- `msg`: a `String` or a byte vector. It is copied, so you may reuse the buffer.

Subscribers are the callbacks registered with
[`subscribe(f, channel)`](@ref subscribe(::Any, ::AbstractString)) and the
WebSocket clients subscribed with
[`subscribe(ws, channel)`](@ref subscribe(::WebSocket, ::AbstractString)).

# Returns
`nothing`. Publishing to a channel nobody subscribes to is not an error.

# Notes
- Safe from any task or thread. Delivery happens later, on the reactor thread;
  `publish` does not wait for it.
- Messages from one publishing thread are delivered in order.
- Pub/sub is local to the process: nothing is sent to other processes or
  machines.

# Examples
A handler that announces to every WebSocket client on the `"chat"` channel:

```jldoctest
julia> using Facil

julia> import Downloads

julia> seen = Channel{String}(8);

julia> sub = subscribe(msg -> put!(seen, msg), "chat");

julia> server = serve!(0) do req
           publish("chat", body(req))
           Response(StatusCodes.NO_CONTENT)
       end;

julia> r = Downloads.request("http://127.0.0.1:\$(port(server))/"; method = "POST", input = IOBuffer("deploy at 5"), output = devnull);

julia> r.status
204

julia> take!(seen)
"deploy at 5"

julia> unsubscribe(sub); close(server)
```
"""
function publish(channel::AbstractString, msg::Union{String,Vector{UInt8}})
    ensure_reactor()
    ch = String(channel)
    GC.@preserve ch msg @ccall LIBFJL.fjl_ps_publish(pointer(ch)::Ptr{UInt8}, sizeof(ch)::Csize_t,
                                                     pointer(msg)::Ptr{UInt8}, sizeof(msg)::Csize_t)::Cint
    nothing
end
publish(channel::AbstractString, msg::AbstractString) = publish(channel, String(msg))
publish(channel::AbstractString, msg::AbstractVector{UInt8}) = publish(channel, Vector{UInt8}(msg))

function ps_on_message(jl::Ptr{Cvoid}, ::Ptr{UInt8}, ::Csize_t, data::Ptr{UInt8}, len::Csize_t)
    try
        s = unsafe_pointer_to_objref(jl)::Subscription
        isopen(s) || return nothing
        msg = unsafe_string(data, len)
        if s.spawn
            Threads.@spawn run_subscriber($s, $msg)
        else
            run_subscriber(s, msg)
        end
    catch e
        callback_error("a subscription", e, catch_backtrace())
    end
    nothing
end

function run_subscriber(s::Subscription, msg::String)
    try
        s.callback(msg)
    catch e
        log_error("a subscription callback", e, catch_backtrace())
    end
    nothing
end

function ps_on_unsubscribe(jl::Ptr{Cvoid})
    try
        s = unsafe_pointer_to_objref(jl)::Subscription
        @atomic s.open = false
        lock(LIVE_SUBS_LOCK)
        delete!(LIVE_SUBS, jl)
        unlock(LIVE_SUBS_LOCK)
    catch e
        callback_error("ending a subscription", e, catch_backtrace())
    end
    nothing
end

function init_pubsub()
    @ccall LIBFJL.fjl_ps_init(@cfunction(ps_on_message, Cvoid, (Ptr{Cvoid}, Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t))::Ptr{Cvoid},
                              @cfunction(ps_on_unsubscribe, Cvoid, (Ptr{Cvoid},))::Ptr{Cvoid})::Cvoid
    atexit(end_subscriptions)
    nothing
end

# facil.io's exit cleanup cannot end subscriptions that are still open, so they
# end here, before the reactor stops; later callbacks are detached from Julia.
function end_subscriptions()
    lock(LIVE_SUBS_LOCK)
    subs = collect(values(LIVE_SUBS))
    unlock(LIVE_SUBS_LOCK)
    foreach(unsubscribe, subs)
    @ccall LIBFJL.fjl_ps_detach()::Cvoid
    nothing
end

precompile(ps_on_message, (Ptr{Cvoid}, Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t))
precompile(publish, (String, String))
