# Limits applied when a server starts, graceful close, and SIGTERM for `serve`.

function apply_limits(cs::Ptr{Cvoid}, opts::ServerOptions)
    @ccall LIBFJL.fjl_http_server_limits(cs::Ptr{Cvoid}, opts.max_pending_output::Csize_t)::Cvoid
    @ccall LIBFJL.http1_header_timeout_set(opts.header_timeout::Csize_t)::Cvoid
    nothing
end

function mib(n::Integer)
    n >= 1 << 20 && n % (1 << 20) == 0 && return string(n >> 20, " MiB")
    n >= 1 << 10 && n % (1 << 10) == 0 && return string(n >> 10, " KiB")
    string(n, " B")
end

function started(@nospecialize(srv::Server))
    o = srv.options
    if o.verbose
        log_line(string("listening on http://", srv.host, ":", srv.port, " (reactor threads ", fjl_reactor_threads(),
                        ", Julia threads ", Threads.nthreads(), ", handlers ", o.inline ? "inline" : "on tasks",
                        "; limits: header ", mib(o.max_header_size), ", body ", mib(o.max_body_size),
                        ", in memory ", mib(o.body_in_memory), ", idle timeout ", o.timeout, " s, header timeout ",
                        o.header_timeout, " s, pending output ", o.max_pending_output == 0 ? "unlimited" : mib(o.max_pending_output), ")"))
    end
    srv
end

drain_start(@nospecialize(s::Server)) =
    @ccall(LIBFJL.fjl_http_drain(s.cserver::Ptr{Cvoid}, 2::Cint)::Cint) == 0

force_close(@nospecialize(s::Server)) =
    if @ccall(LIBFJL.fjl_http_close(s.cserver::Ptr{Cvoid})::Cint) != 0
        @atomic s.state = CLOSED
        notify(s.closed)
    end

"""
    Facil.drain_server!(server::Server, grace::Real)

What [`close(server; grace)`](@ref Base.close(::Server)) does for `grace > 0`:
stop accepting, let each request in progress reply (the reply closes its
connection), close idle connections within about 2 seconds, and after `grace`
seconds close whatever is left. Returns at once; `wait(server)` blocks until the server is closed.
Prefer `close(server; grace)`.
"""
function drain_server!(@nospecialize(s::Server), grace::Real)
    _, ok = @atomicreplace s.state OPEN => CLOSING
    ok || return nothing
    if !drain_start(s)
        force_close(s)
        return nothing
    end
    note(s, "closing :$(s.port), giving open requests up to $(grace) s")
    errormonitor(@async begin
        timedwait(() -> (@atomic s.state) == CLOSED, Float64(grace); pollint = 0.05)
        (@atomic s.state) == CLOSED || force_close(s)
    end)
    nothing
end

# ---- SIGTERM

# Julia answers SIGTERM (and Ctrl-C in a script) by interrupting thread 1 and
# running the atexit hooks there (exit code 128), wherever that thread was.
# The hook hands the drain to WATCHER, a task on another thread, and waits.
const FOREGROUND = Threads.Atomic{Int}(0)
const EXIT_HOOK = Threads.Atomic{Bool}(false)
const EXIT_STUCK = Threads.Atomic{Bool}(false)
const WATCH = Ref{Base.AsyncCondition}()
const WATCHING = Threads.Atomic{Bool}(false)
const DRAIN_IDLE, DRAIN_RUNNING, DRAIN_DONE = 0, 1, 2
const DRAIN = Threads.Atomic{Int}(DRAIN_IDLE)
const WATCHER_ACK_MS = 500

function foreground!(@nospecialize(srv::Server), d::Int)
    Threads.atomic_add!(FOREGROUND, d)
    if d > 0 && !Threads.atomic_xchg!(EXIT_HOOK, true)
        atexit(drain_at_exit)
        start_watcher()
    end
    nothing
end

# Thread 1 runs Julia's event loop and is the thread a signal interrupts, so
# the loop moves to a thread of its own; tasks waiting on I/O then keep
# running while the process drains. The watcher needs a second Julia thread.
function start_watcher()
    isdefined(Base.Experimental, :make_io_thread) || return nothing
    Base.Experimental.make_io_thread()
    Threads.nthreads() > 1 || return nothing
    WATCH[] = Base.AsyncCondition()
    WATCHING[] = true
    Threads.@spawn :default watch_signal()
    nothing
end

function watch_signal()
    try
        wait(WATCH[])
        Threads.atomic_cas!(DRAIN, DRAIN_IDLE, DRAIN_RUNNING) == DRAIN_IDLE || return nothing
        servers = lock(() -> Server[s for s in values(LIVE) if isopen(s)], LIVE_LOCK)
        any(s -> s.options.verbose, servers) && !isempty(servers) &&
            log_line("signal received; closing $(length(servers)) server(s), up to $(maximum(s -> s.options.shutdown_grace, servers)) s for open requests")
        foreach(s -> close(s; grace = s.options.shutdown_grace), servers)
        foreach(wait, servers)
    catch e
        callback_error("draining on a signal", e, catch_backtrace())
    finally
        DRAIN[] = DRAIN_DONE
    end
    nothing
end

sleep_gcsafe(ms::Integer) = (@gcsafe_ccall usleep((1000 * ms)::Cuint)::Cint; nothing)

function live_servers()
    for _ in 1:100
        if trylock(LIVE_LOCK)
            try
                return Server[s for s in values(LIVE)]
            finally
                unlock(LIVE_LOCK)
            end
        end
        sleep_gcsafe(10)
    end
    Server[]
end

# True when the watcher task took the drain and finished it within `limit` s.
function drain_by_watcher(limit::Real)
    WATCHING[] || return false
    ccall(:uv_async_send, Cint, (Ptr{Cvoid},), WATCH[].handle)
    for _ in 1:(WATCHER_ACK_MS ÷ 10)
        DRAIN[] == DRAIN_IDLE || break
        sleep_gcsafe(10)
    end
    Threads.atomic_cas!(DRAIN, DRAIN_IDLE, DRAIN_DONE) == DRAIN_IDLE && return false
    deadline = time() + limit
    while time() < deadline && DRAIN[] != DRAIN_DONE
        sleep_gcsafe(10)
    end
    DRAIN[] == DRAIN_DONE
end

# Runs on the interrupted thread: it must not yield, so it waits in GC-safe sleeps.
function drain_at_exit(code::Integer)
    try
        (code == 128 && FOREGROUND[] > 0 && fjl_is_running() && !fjl_on_reactor()) || return nothing
        servers = filter(s -> (@atomic s.state) != CLOSED, live_servers())
        isempty(servers) && return nothing
        grace = maximum(s -> s.options.shutdown_grace, servers)
        if !drain_by_watcher(grace + 1)
            open = filter(s -> (@atomic s.state) == OPEN, servers)
            any(s -> s.options.verbose, open) &&
                log_line("signal received; closing $(length(open)) server(s), up to $(grace) s for open requests")
            for s in open
                _, ok = @atomicreplace s.state OPEN => CLOSING
                ok && drain_start(s)
            end
            deadline = time() + grace
            while time() < deadline && any(s -> (@atomic s.state) != CLOSED, servers)
                sleep_gcsafe(20)
            end
        end
        for s in servers
            (@atomic s.state) == CLOSED || @ccall LIBFJL.fjl_http_close(s.cserver::Ptr{Cvoid})::Cint
        end
        t = time() + 1
        while time() < t && any(s -> (@atomic s.state) != CLOSED, servers)
            sleep_gcsafe(10)
        end
        # A handler that never returned holds its reactor thread: do not join it.
        any(s -> (@atomic s.state) != CLOSED, servers) && (EXIT_STUCK[] = true)
    catch e
        callback_error("draining at exit", e, catch_backtrace())
    end
    nothing
end
