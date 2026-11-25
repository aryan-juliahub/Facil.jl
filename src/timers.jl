# Waits are timed on the shim's timer thread. A waiting task parks on a pooled
# auto-reset Waker; C holds only the Waker's address, and every Waker ever made
# stays rooted in WAKERS_ALL, so a late fire never touches freed memory.
mutable struct Waker
    const cond::Base.GenericCondition{Threads.SpinLock}
    set::Bool
end
Waker() = Waker(Base.GenericCondition(Threads.SpinLock()), false)

function wait_waker(w::Waker)
    lock(w.cond)
    try
        while !w.set
            wait(w.cond)
        end
        w.set = false
    finally
        unlock(w.cond)
    end
    nothing
end

function notify_waker(w::Waker)
    lock(w.cond)
    w.set = true
    notify(w.cond)
    unlock(w.cond)
    nothing
end

const WAKERS_ALL = Waker[]
const WAKERS_FREE = Waker[]
const WAKERS_LOCK = Threads.SpinLock()
const TIMER_FIRE = Ref{Ptr{Cvoid}}(C_NULL)
const TIMER_READY = Threads.Atomic{Bool}(false)

function take_waker()
    lock(WAKERS_LOCK)
    w = if isempty(WAKERS_FREE)
        x = Waker()
        push!(WAKERS_ALL, x)
        x
    else
        pop!(WAKERS_FREE)
    end
    unlock(WAKERS_LOCK)
    w
end

give_waker(w::Waker) = (lock(WAKERS_LOCK); push!(WAKERS_FREE, w); unlock(WAKERS_LOCK); nothing)

function timer_fire(tokens::Ptr{Ptr{Cvoid}}, n::Cint)
    try
        for i in 1:n
            notify_waker(unsafe_pointer_to_objref(unsafe_load(tokens, i))::Waker)
        end
    catch e
        callback_error("the timer thread", e, catch_backtrace())
    end
    nothing
end

function ensure_timer()
    TIMER_READY[] && return nothing
    TIMER_FIRE[] == C_NULL && (TIMER_FIRE[] = @cfunction(timer_fire, Cvoid, (Ptr{Ptr{Cvoid}}, Cint)))
    r = @ccall LIBFJL.fjl_timer_init(TIMER_FIRE[]::Ptr{Cvoid})::Cint
    r == 0 || error("Facil: could not start the timer thread")
    TIMER_READY[] = true
    nothing
end

timer_now() = @ccall LIBFJL.fjl_timer_now()::UInt64
timer_cancel(w::Waker) = (@ccall LIBFJL.fjl_timer_cancel(pointer_from_objref(w)::Ptr{Cvoid})::Cint) == 1

function arm!(w::Waker, due::UInt64)
    r = @ccall LIBFJL.fjl_timer_at(due::UInt64, pointer_from_objref(w)::Ptr{Cvoid})::Cint
    r == 0 || error("Facil: could not arm a timer")
    nothing
end

# Waits on an armed Waker. If the wait is interrupted and the timer could not be
# withdrawn, its fire is still coming, so the Waker is not reused.
function wait_armed(w::Waker)
    try
        wait_waker(w)
    catch
        timer_cancel(w) && give_waker(w)
        rethrow()
    end
    give_waker(w)
end

function sleep_until(due::UInt64)
    ensure_timer()
    w = take_waker()
    arm!(w, due)
    wait_armed(w)
end

to_ns(s::Real) = s >= 1e9 ? typemax(Int64) % UInt64 : round(UInt64, max(s, 0) * 1e9)

"""
    Facil.sleep(seconds)

Blocks the current task for `seconds`, timed by Facil's timer thread to within
tens of microseconds (`Base.sleep(0.001)` takes about 2.5 ms on macOS). Other
tasks keep running. On a reactor thread (an inline handler) it blocks that
thread instead, stalling its other connections for the duration.
"""
function sleep(s::Real)
    isnan(s) && throw(ArgumentError("sleep time must not be NaN"))
    ns = to_ns(s)
    if ns == 0
        yield()
    elseif fjl_on_reactor()
        @gcsafe_ccall LIBFJL.fjl_timer_sleep(ns::UInt64)::Cvoid
    else
        sleep_until(timer_now() + ns)
    end
    nothing
end

"""
    Facil.Timer(callback, delay; interval = 0)

Runs `callback(timer)` on a Julia task after `delay` seconds and then every
`interval` seconds (once if `interval` is 0), timed like [`Facil.sleep`](@ref).
Ticks that fall behind are skipped, not queued. `close(timer)` stops it; a
callback that throws is logged and stops the timer.
"""
mutable struct Timer
    const waker::Waker
    const interval::UInt64
    @atomic open::Bool
    task::Union{Task,Nothing}
end

function Timer(callback, delay::Real; interval::Real = 0)
    (delay >= 0 && interval >= 0) || throw(ArgumentError("delay and interval must not be negative"))
    ensure_timer()
    t = Timer(take_waker(), to_ns(interval), true, nothing)
    first = timer_now() + to_ns(delay)
    t.task = errormonitor(Threads.@spawn run_timer($t, $callback, $first))
    t
end

function run_timer(t::Timer, callback, due::UInt64)
    w = t.waker
    while true
        arm!(w, due)
        if !(@atomic t.open) && timer_cancel(w)
            give_waker(w)
            return
        end
        wait_waker(w)
        (@atomic t.open) || break
        try
            callback(t)
        catch e
            log_error("a timer callback", e, catch_backtrace())
            @atomic t.open = false
        end
        (@atomic t.open) && t.interval > 0 || break
        now = timer_now()
        due += t.interval
        due <= now && (due += ((now - due) ÷ t.interval + 1) * t.interval)
    end
    @atomic t.open = false
    give_waker(w)
end

Base.isopen(t::Timer) = @atomic t.open

function Base.close(t::Timer)
    _, ok = @atomicreplace t.open true => false
    ok && timer_cancel(t.waker) && notify_waker(t.waker)
    nothing
end

"""
    every(f, ms) -> Facil.Timer

Calls `f()` every `ms` milliseconds on a Julia task, starting `ms` from now,
until `f` returns `false` or the timer is closed.
"""
function every(f, ms::Real)
    ms > 0 || throw(ArgumentError("the interval must be positive"))
    Timer(t -> (f() === false && close(t)), ms / 1000; interval = ms / 1000)
end

function timer_stats()
    out = zeros(UInt64, 3)
    @ccall LIBFJL.fjl_timer_stats(out::Ptr{UInt64})::Cvoid
    (pending = Int(out[1]), wakeups = Int(out[2]), fired = Int(out[3]))
end
