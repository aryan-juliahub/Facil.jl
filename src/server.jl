"""
    ServerOptions(; kw...)

The keywords of [`serve!`](@ref) and [`serve`](@ref), checked once.
"""
# Mutable so that reading it through an untyped `Server` does not copy it.
mutable struct ServerOptions
    const inline::Bool
    const reactors::Int
    const max_header_size::Int
    const max_body_size::Int
    const timeout::Int
    const verbose::Bool
    const body_in_memory::Int
    const before_body::Any
    const header_timeout::Int
    const max_pending_output::Int
    const shutdown_grace::Float64
end

function ServerOptions(; inline::Bool = false, reactors::Integer = 1,
                       max_header_size::Integer = 32 * 1024,
                       max_body_size::Integer = 50 * 1024 * 1024,
                       timeout::Integer = 40, verbose::Bool = false,
                       body_in_memory::Integer = 16 * 1024 * 1024, before_body = default_before_body,
                       header_timeout::Integer = 30, max_pending_output::Integer = 16 * 1024 * 1024,
                       shutdown_grace::Real = 10)
    inline = inline || run_inline_anyway(verbose)
    reactors >= 1 || throw(ArgumentError("reactors must be at least 1"))
    max_header_size >= 1024 || throw(ArgumentError("max_header_size must be at least 1024 bytes"))
    max_body_size >= 0 || throw(ArgumentError("max_body_size must not be negative"))
    1 <= timeout <= 255 || throw(ArgumentError("timeout must be between 1 and 255 seconds"))
    body_in_memory >= 0 || throw(ArgumentError("body_in_memory must not be negative"))
    0 <= header_timeout <= 3600 || throw(ArgumentError("header_timeout must be between 0 (off) and 3600 seconds"))
    max_pending_output >= 0 || throw(ArgumentError("max_pending_output must not be negative"))
    shutdown_grace >= 0 || throw(ArgumentError("shutdown_grace must not be negative"))
    ServerOptions(inline, reactors, max_header_size, max_body_size, timeout, verbose,
                  body_in_memory, before_body, header_timeout, max_pending_output, shutdown_grace)
end

const OPEN, CLOSING, CLOSED = 0, 1, 2

"""
    Server

A listening HTTP server returned by [`serve!`](@ref). `close(s)` stops it,
`wait(s)` blocks until it has stopped, `isopen(s)` and `port(s)` describe it.
"""
mutable struct Server{F}
    const handler::F
    const host::String
    const port::Int
    const options::ServerOptions
    cserver::Ptr{Cvoid}
    @atomic state::Int
    const closed::Base.Event
end

const LIVE = Dict{Ptr{Cvoid},Server}()
const LIVE_LOCK = ReentrantLock()
const ON_REQUEST = Ref{Ptr{Cvoid}}(C_NULL)
const ON_UPGRADE = Ref{Ptr{Cvoid}}(C_NULL)
const ON_CLOSED = Ref{Ptr{Cvoid}}(C_NULL)
const ON_RELEASE = Ref{Ptr{Cvoid}}(C_NULL)

Base.isopen(s::Server) = (@atomic s.state) == OPEN
HttpTypes.port(s::Server) = s.port
Base.wait(s::Server) = (wait(s.closed); nothing)

function Base.show(io::IO, s::Server)
    st = ("open", "closing", "closed")[(@atomic s.state)+1]
    print(io, "Facil.Server(\"", s.host, "\", ", s.port, ", ", st, ")")
end

"""
    close(s::Server)

Stops accepting connections and closes the server's open connections once their
queued output is sent. Returns at once; `wait(s)` blocks until all are gone.
With `grace > 0` requests in progress get up to `grace` seconds to finish first.
"""
function Base.close(s::Server; grace::Real = 0)
    grace > 0 && return drain_server!(s, grace)
    _, ok = @atomicreplace s.state OPEN => CLOSING
    ok || return nothing
    if @ccall(LIBFJL.fjl_http_close(s.cserver::Ptr{Cvoid})::Cint) != 0
        # The reactor stopped, and every listener and connection with it.
        @atomic s.state = CLOSED
        notify(s.closed)
    end
    nothing
end

connections(s::Server) = (@atomic s.state) == CLOSED ? 0 :
    Int(@ccall LIBFJL.fjl_http_connections(s.cserver::Ptr{Cvoid})::Csize_t)

function on_request(h::Ptr{Cvoid})
    try
        srv = unsafe_pointer_to_objref(fjl_server_udata(h))::Server
        handle(srv, h)
    catch e
        callback_error("on_request", e, catch_backtrace())
    end
    nothing
end

function handle(@nospecialize(srv::Server), h::Ptr{Cvoid})
    req = try
        read_request(srv, h)
    catch
        fail(h, 400)
        return nothing
    end
    req === nothing && return nothing
    t = stream_task(req)
    t === nothing || return handle_stream_async(srv, h, req, t)
    srv.options.inline || return handle_async(srv, h, req)
    res = try
        srv.handler(req)
    catch e
        log_error("a request handler", e, catch_backtrace())
        fail(h, 500)
        return nothing
    end
    try
        res isa Response{String} ? respond(h, res) : respond(h, res)
    catch e
        log_error("a request handler's result", e, catch_backtrace())
        fail(h, 500)
    end
    nothing
end

# Upgrade requests (WebSocket, and SSE by Accept header) reach the same handler.
on_upgrade(h::Ptr{Cvoid}, ::Ptr{UInt8}, ::Csize_t) = on_request(h)

fail(h::Ptr{Cvoid}, status::Int) = (@ccall LIBFJL.fjl_resp_error(h::Ptr{Cvoid}, status::Cint)::Cint; nothing)

function on_closed(settings::Ptr{Cvoid})
    try
        srv = unsafe_pointer_to_objref(fjl_settings_udata(settings))::Server
        @atomic srv.state = CLOSED
        notify(srv.closed)
    catch e
        callback_error("closing a server", e, catch_backtrace())
    end
    nothing
end

function on_release(udata::Ptr{Cvoid})
    try
        lock(() -> delete!(LIVE, udata), LIVE_LOCK)
    catch e
        callback_error("releasing a server", e, catch_backtrace())
    end
    nothing
end

const EADDRINUSE = Sys.isapple() ? 48 : 98

function listen!(srv::Server, cs::Ptr{Cvoid}, host::String, port::String)
    call = GC.@preserve host port await_call(c -> @ccall LIBFJL.fjl_http_listen_async(
        cs::Ptr{Cvoid}, pointer(host)::Ptr{UInt8}, pointer(port)::Ptr{UInt8}, c::Ptr{FjlCall})::Cint)
    call === nothing && error("Facil: the reactor is not running")
    call.result >= 0 ? 0 : Int(call.err)
end

"""
    serve!(handler, host = "127.0.0.1", port = 8080; kw...) -> Server
    serve!(handler, port::Integer; kw...)

Starts an HTTP server and returns it without blocking. `handler(req::Request{String})`
returns a `Response` (body `String`, `Vector{UInt8}` or `nothing`) or a `String`,
which is sent as `200 text/plain`. Port 0 picks a free port; `port(server)` tells which.

A response body is sent without a copy and must not be changed afterwards. A
non-empty body without a `content-type` gets `text/plain; charset=utf-8` (string)
or `application/octet-stream` (bytes); `content-length` is always set by Facil.
A handler that throws, or returns anything else, gives a 500; the error is logged
to stderr once per error type every 10 seconds. A request facil.io parsed but
HttpTypes rejects (bad target or header name) gets a 400.

Keywords:
- `inline = false`: run each handler on its own Julia task, so it may block (use
  [`Facil.sleep`](@ref) for short waits). With one Julia thread handlers run inline
  anyway. `inline = true` runs them on the reactor thread: faster for short
  handlers, but one that blocks stalls every connection on that thread.
- `reactors = 1`: reactor threads, shared by every server in the process; fixed by the first server.
- `max_header_size = 32768`, `max_body_size = 50 MiB`: larger requests are refused (431/413).
- `timeout = 40`: seconds an idle keep-alive connection is kept (1–255).
- `before_body = head -> Buffer()`: called with a [`RequestHead`](@ref) when a body
  starts; returns `Buffer()`, `Stream()`, `Spool()` or `Reject(status)`.
- `body_in_memory = 16 MiB`: largest `Buffer()` body; larger ones get a 413.
- `header_timeout = 30`: seconds a client has to send a request head, else 408
  (0 disables). Process-wide: the last server started sets it.
- `max_pending_output = 16 MiB`: a client with more unsent response bytes queued
  that stops reading for about 3 s is disconnected (0 disables).
- `shutdown_grace = 10`: seconds `serve` gives open requests to finish on SIGTERM.
- `verbose = false`: log start-up, limits and rejected requests to stderr.
- `tls = nothing`: a [`TLSConfig`](@ref) serves HTTPS instead (needs `reactors = 1`).
- `public_folder = nothing`: a directory whose files are served (GET, HEAD,
  OPTIONS) before the handler is called; see [`sendfile`](@ref) for the headers.
  Requests for anything else, and other methods, reach the handler.
- `compress = false`: `true` or a [`CompressOptions`](@ref) compresses handler
  results (zstd, br, gzip by `Accept-Encoding`) on the handler's task.
- `gc_headroom = 0`: bytes of heap headroom, see [`Facil.gc_headroom!`](@ref).
"""
serve!(handler, port::Integer; kw...) = serve!(handler, "127.0.0.1", port; kw...)

function serve!(handler, host::AbstractString = "127.0.0.1", port::Integer = 8080; tls = nothing,
                public_folder::Union{Nothing,AbstractString} = nothing, compress = false,
                gc_headroom::Integer = 0, kw...)
    opts = ServerOptions(; kw...)
    gc_headroom > 0 && gc_headroom!(gc_headroom)
    handler = wrap_handler(handler, compress_options(compress))
    folder = static_folder(public_folder)
    tls === nothing || check_tls_options(tls, opts)
    0 <= port <= 65535 || throw(ArgumentError("port must be in 0:65535"))
    h = String(host)
    occursin('\0', h) && throw(ArgumentError("host must not contain NUL"))
    ensure_reactor(; threads = opts.reactors)
    n = fjl_reactor_threads()
    n == opts.reactors || throw(ArgumentError("the reactor is already running with $n thread(s); every server shares it, so reactors = $(opts.reactors) cannot be honoured"))
    attempts = port == 0 ? 20 : 1
    for _ in 1:attempts
        p = port == 0 ? Int(@ccall LIBFJL.fjl_http_free_port(h::Cstring)::Cint) : Int(port)
        p == 0 && error("Facil: no free port on $(repr(h))")
        srv = Server{typeof(handler)}(handler, h, p, opts, C_NULL, OPEN, Base.Event())
        key = pointer_from_objref(srv)
        ctls = tls === nothing ? C_NULL : tls_object(tls)
        lo = ListenOptions(ON_REQUEST[]; on_upgrade = ON_UPGRADE[], on_finish = ON_CLOSED[], udata = key,
                           max_header_size = opts.max_header_size, max_body_size = opts.max_body_size,
                           timeout = opts.timeout, log = false, tls = ctls,
                           public_folder = folder === nothing ? Ptr{UInt8}(C_NULL) : pointer(folder))
        cs = GC.@preserve folder @ccall LIBFJL.fjl_http_server_new(Ref(lo)::Ptr{ListenOptions}, ON_RELEASE[]::Ptr{Cvoid})::Ptr{Cvoid}
        cs == C_NULL && (ctls == C_NULL || tls_free(ctls); error("Facil: could not allocate a server"))
        srv.cserver = cs
        apply_limits(cs, opts)
        lock(() -> (LIVE[key] = srv), LIVE_LOCK)
        err = listen!(srv, cs, h, string(p))
        err == 0 && return started(srv)
        lock(() -> delete!(LIVE, key), LIVE_LOCK)
        @ccall LIBFJL.fjl_http_server_free(cs::Ptr{Cvoid})::Cvoid
        (port == 0 && err == EADDRINUSE) && continue
        throw(SystemError("Facil: listening on $h:$p", err))
    end
    error("Facil: no free port on $(repr(h)) after $attempts attempts")
end

const GC_HEADROOM = Ref{Vector{UInt8}}(UInt8[])
const GC_HEADROOM_LOCK = ReentrantLock()

"""
    Facil.gc_headroom!(bytes) -> Int

Keeps a never-written block of `bytes` alive so the collector sizes its heap as
if that much more were live: fewer collections when handlers allocate large
temporaries. It costs address space, not memory. Process-wide; it only grows.
Returns the headroom now held.
"""
function gc_headroom!(bytes::Integer)
    bytes >= 0 || throw(ArgumentError("gc_headroom must not be negative"))
    lock(GC_HEADROOM_LOCK) do
        bytes > length(GC_HEADROOM[]) && (GC_HEADROOM[] = Vector{UInt8}(undef, bytes))
        length(GC_HEADROOM[])
    end
end

"""
    serve(handler, host = "127.0.0.1", port = 8080; kw...)

Like [`serve!`](@ref) but blocks until the server is closed; Ctrl-C closes it.

```julia
serve("127.0.0.1", 8080) do req
    Response(StatusCodes.OK, "hello")
end
```
"""
function serve(handler, args...; kw...)
    srv = serve!(handler, args...; kw...)
    foreground!(srv, 1)
    try
        wait(srv)
    catch e
        e isa InterruptException || rethrow()
    finally
        foreground!(srv, -1)
        close(srv)
    end
    wait(srv)
    nothing
end

function init_server()
    init_http_tables()
    ON_REQUEST[] = @cfunction(on_request, Cvoid, (Ptr{Cvoid},))
    ON_UPGRADE[] = @cfunction(on_upgrade, Cvoid, (Ptr{Cvoid}, Ptr{UInt8}, Csize_t))
    ON_CLOSED[] = @cfunction(on_closed, Cvoid, (Ptr{Cvoid},))
    ON_RELEASE[] = @cfunction(on_release, Cvoid, (Ptr{Cvoid},))
    BODY_DEALLOC[] = @cfunction(body_released, Cvoid, (Ptr{Cvoid},))
    nothing
end
