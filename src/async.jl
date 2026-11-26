# Task handlers: on_request reads the request, pauses the connection and spawns
# the handler. The finished result waits here, keyed by request id, until the
# reactor resumes the connection (on_resume) or finds it closed (on_drop).
const RESULT_SHARDS = 32
const RESULTS = [Dict{UInt64,Any}() for _ in 1:RESULT_SHARDS]
const RESULT_LOCKS = [Threads.SpinLock() for _ in 1:RESULT_SHARDS]
const NEXT_ID = Threads.Atomic{UInt64}(0)
const ON_RESUME = Ref{Ptr{Cvoid}}(C_NULL)
const ON_DROP = Ref{Ptr{Cvoid}}(C_NULL)
const DROPPED = Threads.Atomic{Int}(0)

@inline shard(id::UInt64) = (id % RESULT_SHARDS) % Int + 1

function put_result!(id::UInt64, res)
    i = shard(id)
    l = @inbounds RESULT_LOCKS[i]
    lock_sigatomic(l)
    @inbounds RESULTS[i][id] = res
    unlock_sigatomic(l)
    nothing
end

function take_result!(id::UInt64)
    i = shard(id)
    l = @inbounds RESULT_LOCKS[i]
    lock_sigatomic(l)
    res = pop!(@inbounds(RESULTS[i]), id, nothing)
    unlock_sigatomic(l)
    res
end

"A handler that threw; the reactor answers 500."
struct HandlerFailed end

async_pause(h::Ptr{Cvoid}, id::UInt64) = @ccall LIBFJL.fjl_async_pause(h::Ptr{Cvoid}, id::UInt64)::Ptr{Cvoid}
async_done(a::Ptr{Cvoid}) = @ccall LIBFJL.fjl_async_done(a::Ptr{Cvoid})::Cint

"""
    Facil.paused_requests() -> Int

The number of requests whose task handler is running (or waiting for a worker)
right now, across every server. Inline handlers are never counted. A value
that stays high means handlers are slower than requests arrive.
"""
paused_requests() = Int(@ccall LIBFJL.fjl_async_inflight()::Csize_t)

# Jobs run on long-lived worker tasks that wait in C between jobs, so an idle
# worker thread sleeps instead of spinning in the scheduler.
const JOBS = Any[]
const JOBS_LOCK = Threads.SpinLock()
const WORKER_WAIT_MS = 20

work_offer() = @ccall LIBFJL.fjl_work_offer()::Cint
work_wait(max_idle::Integer) =
    @gcsafe_ccall LIBFJL.fjl_work_wait(max_idle::Cint, WORKER_WAIT_MS::Cint)::Cint
fjl_work_idle() = Int(@ccall LIBFJL.fjl_work_idle()::Cint)

# One default-pool thread besides thread 1 stays out of the pool, so tasks that
# yielded, and tasks the main thread waits on, always have a thread.
max_workers() = Threads.nthreads(:default) - (Threads.nthreads(:interactive) == 0 ? 2 : 1)

# Runnable tasks queued in this thread's pool, besides `SPAWNED` runners.
@static if isdefined(Base, :Partr) && isdefined(Base.Partr, :heaps)
    function others_waiting()
        tp = ccall(:jl_threadpoolid, Int8, (Int16,), Threads.threadid() - 1) + 1
        tp == 0 && return false
        n = 0
        for h in Base.Partr.heaps[tp]
            n += Int(@atomic :monotonic h.ntasks)
        end
        n > SPAWNED[]
    end
else
    others_waiting() = false
end

# Julia's run queue is not first-in first-out, so a steady stream of new tasks
# can starve old ones: at most one runner task waits to start at any time, and
# each runner that takes a job hands what is left to the next one.
const SPAWNED = Threads.Atomic{Int}(0)
const WORKERS = Threads.Atomic{Int}(0)

function spawn_runner()
    Threads.atomic_cas!(SPAWNED, 0, 1) == 0 || return nothing
    Threads.@spawn :default run_then_work()
    nothing
end

jobs_waiting() = (lock_sigatomic(JOBS_LOCK); n = !isempty(JOBS); unlock_sigatomic(JOBS_LOCK); n)

# Runs `f()` on an idle worker, else on whichever runner or worker is free
# first. `f` catches its own errors.
function submit(@nospecialize(f))
    lock_sigatomic(JOBS_LOCK)
    push!(JOBS, f)
    unlock_sigatomic(JOBS_LOCK)
    work_offer() == 1 && return nothing
    spawn_runner()
end

# A runner takes jobs until other tasks are waiting for a thread, then becomes
# one of at most max_workers() workers, or ends.
function run_then_work()
    Threads.atomic_sub!(SPAWNED, 1)
    run_jobs() || return nothing
    if Threads.atomic_add!(WORKERS, 1) < max_workers()
        try
            worker_loop()
        finally
            Threads.atomic_sub!(WORKERS, 1)
        end
    else
        Threads.atomic_sub!(WORKERS, 1)
    end
    nothing
end

# Runs queued jobs; false when it stopped after a job because other tasks wait
# for a thread (jobs left over then have a runner).
function run_jobs()
    while true
        f = take_job()
        f === nothing && return true
        jobs_waiting() && spawn_runner()
        Base.invokelatest(f)
        others_waiting() && (jobs_waiting() && spawn_runner(); return false)
    end
end

function take_job()
    lock_sigatomic(JOBS_LOCK)
    f = isempty(JOBS) ? nothing : popfirst!(JOBS)
    unlock_sigatomic(JOBS_LOCK)
    f
end

# A worker runs queued jobs before it waits, stops when it shares a thread with
# sticky tasks (they could not run while it waits in C) or when other tasks
# wait for a thread, and never waits on thread 1.
function worker_loop()
    n = max_workers()
    n < 1 && return nothing
    t = current_task()
    while !t.sticky && Threads.threadid() != 1 && isempty(Base.workqueue_for(Threads.threadid()))
        (run_jobs() && !others_waiting()) || return nothing
        r = work_wait(n)
        r < 0 && return nothing
        r == 0 && continue
        f = take_job()
        f === nothing || Base.invokelatest(f)
    end
    nothing
end

function handle_async(@nospecialize(srv::Server), h::Ptr{Cvoid}, req)
    id = Threads.atomic_add!(NEXT_ID, UInt64(1)) + UInt64(1)
    a = async_pause(h, id)
    if a == C_NULL
        fail(h, 503)
        return nothing
    end
    submit(() -> run_handler(srv, req, a, id))
    nothing
end

function run_handler(@nospecialize(srv::Server), req, a::Ptr{Cvoid}, id::UInt64)
    res = try
        srv.handler(req)
    catch e
        log_error("a request handler", e, catch_backtrace())
        HandlerFailed()
    end
    put_result!(id, res)
    async_done(a)
    nothing
end

function on_resume(h::Ptr{Cvoid}, id::UInt64)
    try
        res = take_result!(id)
        if res === nothing || res isa HandlerFailed
            fail(h, 500)
        else
            try
                respond(h, res)
            catch e
                log_error("a request handler's result", e, catch_backtrace())
                fail(h, 500)
            end
        end
    catch e
        callback_error("resuming a request", e, catch_backtrace())
    end
    nothing
end

function on_drop(id::UInt64)
    try
        take_result!(id)
        Threads.atomic_add!(DROPPED, 1)
    catch e
        callback_error("dropping a request", e, catch_backtrace())
    end
    nothing
end

const ONE_THREAD_NOTED = Threads.Atomic{Bool}(false)

# Task handlers on a single Julia thread measured at under half the inline speed.
function run_inline_anyway(verbose::Bool)
    Threads.nthreads(:default) > 1 && return false
    if verbose && !Threads.atomic_xchg!(ONE_THREAD_NOTED, true)
        msg = "Facil: Julia has one thread, so handlers run inline on the reactor; start julia with -t N for task handlers\n"
        ccall(:write, Cssize_t, (Cint, Ptr{UInt8}, Csize_t), 2, msg, sizeof(msg))
    end
    true
end

function init_async()
    ON_RESUME[] = @cfunction(on_resume, Cvoid, (Ptr{Cvoid}, UInt64))
    ON_DROP[] = @cfunction(on_drop, Cvoid, (UInt64,))
    @ccall LIBFJL.fjl_async_init(ON_RESUME[]::Ptr{Cvoid}, ON_DROP[]::Ptr{Cvoid})::Cvoid
    nothing
end
