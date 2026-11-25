# Process-local pub/sub on facil.io's post office. A Subscription stays in
# LIVE_SUBS until facil.io reports it gone (on_unsubscribe).

"""
    Subscription

A process-local subscription returned by [`subscribe`](@ref); end it with
`unsubscribe(sub)` or `close(sub)`.
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
    subscribe(f, channel; spawn = false) -> Subscription

Calls `f(msg::String)` for every message [`publish`](@ref)ed to `channel` in this
process, in publishing order. `f` runs on the reactor thread and must not block,
unless `spawn = true`, which runs each call on its own Julia task (order is then
not kept). To forward a channel to WebSocket clients, use
`subscribe(ws, channel)`, which runs no Julia code per message.
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
    unsubscribe(sub::Subscription)

Ends the subscription; no call to its function starts afterwards.
"""
function unsubscribe(s::Subscription)
    _, ok = @atomicreplace s.open true => false
    ok && @ccall LIBFJL.fjl_ps_unsubscribe(s.ptr::Ptr{Cvoid})::Cvoid
    nothing
end
Base.close(s::Subscription) = unsubscribe(s)

"""
    publish(channel, msg) -> Nothing

Sends `msg` (a `String` or bytes) to every subscriber of `channel` in this
process: [`subscribe`](@ref) callbacks and WebSocket clients subscribed with
`subscribe(ws, channel)`. Works from any thread; delivery happens on the reactor.
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
