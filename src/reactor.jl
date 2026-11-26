const REACTOR_LOCK = ReentrantLock()
const POSTED = Dict{UInt,Any}()
const POSTED_LOCK = Threads.SpinLock()
const POSTED_NEXT = Threads.Atomic{UInt}(0)
const RUN_POSTED = Ref{Ptr{Cvoid}}(C_NULL)
const CANCEL_POSTED = Ref{Ptr{Cvoid}}(C_NULL)

# Writes straight to fd 2: Julia's stderr stream needs the event loop, which may
# be waiting on the reactor thread this runs on.
function callback_error(where::AbstractString, e, bt)
    msg = try
        sprint() do io
            print(io, "Facil: uncaught error in ", where, ": ")
            showerror(io, e, bt)
            println(io)
        end
    catch
        "Facil: uncaught error in $where\n"
    end
    ccall(:write, Cssize_t, (Cint, Ptr{UInt8}, Csize_t), 2, msg, sizeof(msg))
    nothing
end

reactor_running() = fjl_is_running()

"""
    start_reactor(; threads = 1) -> Bool

Starts the process-wide facil.io reactor on its own thread. Returns `false` if
it was already running. Normally called lazily through [`ensure_reactor`](@ref).
"""
function start_reactor(; threads::Integer = 1)
    threads >= 1 || throw(ArgumentError("threads must be at least 1"))
    lock(REACTOR_LOCK) do
        fjl_is_running() && return false
        r = fjl_start(threads)
        r == 0 || error("Facil: could not start the reactor (fjl_start returned $r)")
        true
    end
end

ensure_reactor(; threads::Integer = 1) = (fjl_is_running() || start_reactor(; threads); nothing)

"""
    stop_reactor() -> Bool

Stops the reactor and closes every listener. Blocks until its threads exit.
Each restart makes Julia adopt new thread ids, so servers keep one reactor alive.
"""
function stop_reactor()
    fjl_on_reactor() && error("Facil: stop_reactor cannot be called from a reactor thread")
    lock(REACTOR_LOCK) do
        fjl_stop() == 0
    end
end

function take_posted(a::Ptr{Cvoid})
    id = UInt(a)
    lock_sigatomic(POSTED_LOCK)
    f = pop!(POSTED, id, nothing)
    unlock_sigatomic(POSTED_LOCK)
    f
end

function run_posted(a::Ptr{Cvoid}, ::Ptr{Cvoid}, ::Ptr{Cvoid})
    try
        f = take_posted(a)
        f === nothing || f()
    catch e
        callback_error("a task posted to the reactor", e, catch_backtrace())
    end
    nothing
end

function cancel_posted(a::Ptr{Cvoid}, ::Ptr{Cvoid}, ::Ptr{Cvoid})
    try
        take_posted(a)
    catch e
        callback_error("cancelling a posted task", e, catch_backtrace())
    end
    nothing
end

"""
    on_reactor(f) -> Bool

Runs `f()` on a reactor thread at its next wake-up. Returns `false` (and drops
`f`) when the reactor is not running; `f` is also dropped if the reactor stops first.
"""
function on_reactor(f)
    id = Threads.atomic_add!(POSTED_NEXT, UInt(1)) + UInt(1)
    lock_sigatomic(POSTED_LOCK)
    POSTED[id] = f
    unlock_sigatomic(POSTED_LOCK)
    if fjl_post(RUN_POSTED[], CANCEL_POSTED[], Ptr{Cvoid}(id)) != 0
        take_posted(Ptr{Cvoid}(id))
        return false
    end
    true
end

function init_reactor()
    fjl_log_level(get(ENV, "FACIL_VERBOSE", "") in ("1", "true") ? 4 : 3)
    RUN_POSTED[] = @cfunction(run_posted, Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}))
    CANCEL_POSTED[] = @cfunction(cancel_posted, Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}))
    atexit() do
        fjl_is_running() && !fjl_on_reactor() && !EXIT_STUCK[] && fjl_stop_blocking()
    end
    nothing
end
