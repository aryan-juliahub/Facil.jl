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

A listening HTTP server, returned by [`serve!`](@ref).

A `Server` is not constructed directly. It supports:

| Call | Result |
|:--|:--|
| [`close(server; grace = 0)`](@ref Base.close(::Server)) | stop listening and close its connections |
| [`wait(server)`](@ref Base.wait(::Server)) | block until it has stopped |
| [`isopen(server)`](@ref Base.isopen(::Server)) | `true` until `close` is called |
| [`port(server)`](@ref HttpTypes.port(::Server)) | the port it listens on |
| [`Facil.connections(server)`](@ref) | open connections |
| [`reload!(server; cert, key)`](@ref reload!) | replace an HTTPS server's certificate |

`show` prints the address and state, for example
`Facil.Server("127.0.0.1", 8080, open)`. The states are `open`, `closing`
(after `close`, while connections finish) and `closed`.

Every server in a process shares one reactor. A process may run several
servers, each with its own handler, limits and `inline` setting.

# Examples
```jldoctest
julia> using Facil

julia> server = serve!(req -> "ok", 0);

julia> isopen(server)
true

julia> close(server); wait(server)

julia> isopen(server)
false
```
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

"""
    isopen(server::Server) -> Bool

Whether `server` is still accepting connections.

Returns `true` from [`serve!`](@ref) until [`close`](@ref Base.close(::Server))
is called on it (or the reactor stops), and `false` afterwards, including while
its last connections are still finishing. Use [`wait`](@ref Base.wait(::Server))
to learn when those are gone.
"""
Base.isopen(s::Server) = (@atomic s.state) == OPEN
"""
    port(server::Server) -> Int

The TCP port `server` listens on.

For a server started on port `0` this is the free port Facil picked, which is
how tests find their server.

# Examples
```jldoctest
julia> using Facil

julia> server = serve!(req -> "ok", 0);

julia> 1024 <= port(server) <= 65535
true

julia> close(server)
```
"""
HttpTypes.port(s::Server) = s.port
"""
    wait(server::Server)

Block the calling task until `server` has stopped: it no longer listens and
every one of its connections is closed.

Returns `nothing`. Returns at once for a server that is already closed.
[`serve`](@ref) is `serve!` followed by `wait`. Pair it with
[`close`](@ref Base.close(::Server)) from another task, a timer or a signal;
on its own it blocks for as long as the server runs.
"""
Base.wait(s::Server) = (wait(s.closed); nothing)

function Base.show(io::IO, s::Server)
    st = ("open", "closing", "closed")[(@atomic s.state)+1]
    print(io, "Facil.Server(\"", s.host, "\", ", s.port, ", ", st, ")")
end

"""
    close(server::Server; grace = 0)

Stop `server`. Returns `nothing` at once; [`wait(server)`](@ref Base.wait(::Server))
blocks until it has stopped.

# Keywords
- `grace::Real = 0`: seconds that requests in progress get to finish.
  - `0`: stop listening and close every connection as soon as the output
    already queued for it is sent. A handler that is still running finishes,
    but its response is discarded.
  - `> 0`: stop listening, let each request in progress reply (the reply
    closes its connection), close idle connections within about 2 seconds,
    and close whatever is left after `grace` seconds. Other servers in the
    process are not affected.

# Notes
- Calling `close` again, or on a closed server, does nothing.
- The reactor keeps running for the life of the process; closing a server
  closes only its listener and its connections.
- WebSocket connections are closed without a close frame and their
  `on_close` runs (`on_shutdown` does not). Streamed responses and event
  streams are cut; their `isopen(io)` turns `false`. With `grace`, such
  long-lived connections keep the server open until `grace` runs out.
- [`serve`](@ref) calls `close` for you on Ctrl-C at the REPL, and drains
  with `shutdown_grace` on SIGTERM.

# Examples
```jldoctest
julia> using Facil

julia> server = serve!(req -> "ok", 0);

julia> close(server; grace = 5)

julia> wait(server)

julia> occursin("closed", string(server))
true
```

See the [shutdown guide](@ref shutdown-guide).
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

"""
    Facil.connections(server::Server) -> Int

The number of connections `server` holds open right now: idle keep-alive
connections, requests in progress, streams, and WebSockets upgraded on it.
`0` for a closed server. Useful for a metrics endpoint or to watch a drain.
"""
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
    serve!(handler, port::Integer; kw...) -> Server

Start an HTTP server and return it without blocking.

`handler` is called once per request with a [`Request`](@ref)`{String}` and
returns the response. It is the first argument, so `do` syntax works.

# Arguments
- `handler`: any callable `handler(req) -> result`. `result` is one of
  - a [`Response`](@ref) whose body is a `String`, a `Vector{UInt8}` or `nothing`;
  - a `String`, sent as `200` with `content-type: text/plain; charset=utf-8`;
  - what [`stream`](@ref), [`sse`](@ref), [`sendfile`](@ref) or [`websocket`](@ref) returns.
- `host::AbstractString = "127.0.0.1"`: the address to bind. `"0.0.0.0"` listens
  on every IPv4 interface, `"::1"` and `"::"` are the IPv6 forms, and a host
  name such as `"localhost"` is resolved.
- `port::Integer = 8080`: `0` to `65535`. `0` picks a free port; read it back
  with [`port(server)`](@ref HttpTypes.port(::Server)).

# Keywords
Handlers and threads (see the [handlers guide](@ref handlers-guide)):
- `inline::Bool = false`: `false` runs the handler on a task of Facil's worker
  pool, so it may block (wait for I/O, take a lock, call [`Facil.sleep`](@ref)).
  `true` runs it on the reactor thread, inside the event loop: less work per
  request, but a handler that blocks stalls every connection on that thread.
  When Julia has one thread (`julia -t 1`) handlers always run inline.
- `reactors::Integer = 1`: reactor threads. Process-wide: the first server
  fixes the number and a later server asking for another throws.

Limits (see [Limits](@ref limits-reference)):
- `max_header_size::Integer = 32768`: bytes of request head; more gets a `431`. At least 1024.
- `max_body_size::Integer = 50 MiB`: bytes of request body; more gets a `413`.
- `body_in_memory::Integer = 16 MiB`: largest body [`Buffer`](@ref) keeps in memory; more gets a `413`.
- `timeout::Integer = 40`: seconds an idle connection is kept open, `1` to `255`.
- `header_timeout::Integer = 30`: seconds a client has to send a complete
  request head. A client still trickling its head after that gets a `408` and
  is disconnected; one that has gone silent is closed by `timeout` instead.
  `0` turns the check off, at most `3600`. Process-wide: the last server
  started sets it.
- `max_pending_output::Integer = 16 MiB`: a client with more unsent response
  bytes than this that stops reading for about 3 seconds is disconnected; `0`
  turns the check off.

Request bodies (see the [request bodies guide](@ref bodies-guide)):
- `before_body = head -> Buffer()`: called with a [`RequestHead`](@ref) when a
  request has a body, before the body is read. Returns [`Buffer`](@ref)`()`,
  [`Stream`](@ref)`()`, [`Spool`](@ref)`()` or [`Reject`](@ref)`(status)`. It
  runs on the reactor thread and must not block.

Responses:
- `compress = false`: `true` or a [`CompressOptions`](@ref) compresses handler
  results (zstd, brotli or gzip, chosen from `Accept-Encoding`), on the thread
  that ran the handler.
- `public_folder::Union{Nothing,AbstractString} = nothing`: a directory whose
  files are served for `GET`, `HEAD` and `OPTIONS` before the handler is
  called; requests that match no file reach the handler. See [`sendfile`](@ref)
  for the headers.

HTTPS:
- `tls = nothing`: a [`TLSConfig`](@ref) makes this an HTTPS server. Needs `reactors = 1`.

Operation:
- `shutdown_grace::Real = 10`: seconds [`serve`](@ref) gives requests in
  progress when the process gets SIGTERM. See [`serve`](@ref) for which
  handlers can use them.
- `verbose::Bool = false`: write one line to stderr at start-up (address,
  threads, limits), one for each request that `before_body` rejects or that
  is over `body_in_memory`, and one when the server starts to drain.
- `gc_headroom::Integer = 0`: bytes of heap headroom; see [`Facil.gc_headroom!`](@ref).

# Returns
The running [`Server`](@ref). The listener is bound when `serve!` returns, so a
client may connect at once.

# Throws
- `ArgumentError`: a keyword out of range, `port` outside `0:65535`, a NUL in
  `host`, `public_folder` that is not a directory, `tls` that is not a
  `TLSConfig`, `tls` with `reactors > 1`, or `reactors` different from the
  reactor already running.
- `SystemError`: the address could not be bound, for example
  `Address already in use` when another process holds the port.
- `MethodError`: an unknown keyword.

# What Facil does around the handler
- A handler that throws, or returns anything not listed above, gives a `500`
  with the body `Internal Server Error`. The error and its stack trace are
  written to stderr, at most once per error type every 10 seconds.
- A request whose target or header names HttpTypes rejects gets a `400`
  without reaching the handler. So does a request without a `Host` header.
- `content-length` (or chunked framing) is always set by Facil; a
  `content-length` or `transfer-encoding` you set is ignored. A non-empty body
  without `content-type` gets `text/plain; charset=utf-8` (a `String`) or
  `application/octet-stream` (bytes). facil.io adds `date`, `last-modified`
  and `connection` when you did not set them.
- A response body is sent without a copy. Do not change a `Vector{UInt8}`
  after returning it.
- A `HEAD` request gets the head your handler produced, without the body.
- A client that disconnects while its handler runs is not noticed: the
  handler finishes and its result is discarded.

# Examples
```jldoctest
julia> using Facil

julia> import Downloads

julia> server = serve!(0) do req
           if path(uri(req)) == "/"
               Response(StatusCodes.OK, "home")
           else
               Response(StatusCodes.NOT_FOUND, "no such page")
           end
       end;

julia> base = "http://127.0.0.1:\$(port(server))";

julia> String(take!(Downloads.download(base * "/", IOBuffer())))
"home"

julia> Downloads.request(base * "/nope").status
404

julia> close(server)
```

`serve!` with options, as a server meant for short non-blocking handlers:

```jldoctest
julia> using Facil

julia> server = serve!(req -> "pong", "127.0.0.1", 0; inline = true, max_body_size = 1024, timeout = 10);

julia> isopen(server)
true

julia> close(server)
```

See also [`serve`](@ref), [`Server`](@ref), and the
[configuration reference](@ref configuration-reference).
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
    Facil.gc_headroom!(bytes::Integer) -> Int

Keep `bytes` of heap headroom so Julia's garbage collector runs less often.

Facil holds a block of `bytes` that is allocated but never written. The
collector sizes its heap from what is live, so it behaves as if that much more
were in use: fewer collections when handlers allocate large temporaries. The
block costs address space, not resident memory.

# Arguments
- `bytes`: the headroom wanted, `>= 0`.

# Returns
The headroom now held, in bytes. Headroom only grows: a smaller `bytes` than
before changes nothing, and `gc_headroom!(0)` just reports the current value.

# Throws
- `ArgumentError` if `bytes` is negative.

# Notes
Process-wide. `serve!(...; gc_headroom = n)` calls this. It does not help every
load: measure before keeping it (see the [performance guide](@ref performance-guide)).

# Examples
```jldoctest
julia> using Facil

julia> Facil.gc_headroom!(0) >= 0
true
```
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
    serve(handler, port::Integer; kw...)

Start an HTTP server and block until it is closed.

Takes the arguments and keywords of [`serve!`](@ref) and throws what it throws.
Use `serve` as the last line of a server program and `serve!` when the program
has more to do (tests, several servers, a REPL session).

# Returns
`nothing`, once the server has stopped.

# Stopping
- At the REPL, Ctrl-C closes the server and `serve` returns.
- SIGTERM (`kill <pid>`, `systemctl stop`, `docker stop`) drains: the server
  stops accepting, requests in progress get up to `shutdown_grace` seconds
  (default 10), and the process exits with status 143. Julia prints its own
  `signal 15: Terminated` report to stderr first; that is not an error.
  Only handlers that are computing or waiting in [`Facil.sleep`](@ref) can
  finish during this drain. Julia's event loop has stopped by then, so a
  handler waiting on a socket, a file, a process or `Base.sleep` never
  returns and its client is cut off when the grace period ends. To drain
  those, call `close(server; grace)` yourself before the process is stopped;
  see the [shutdown guide](@ref shutdown-guide).
- In a script (`julia server.jl`), Ctrl-C ends the process the way Julia ends
  any script on SIGINT: Julia prints its `signal 2: Interrupt` report, then
  the same drain runs and the process exits.
- Under `julia -e`, or after `Base.exit_on_sigint(false)`, Ctrl-C does not
  stop `serve`. Send SIGTERM.
- Another task may call `close(server)`; `serve` does not hand you the server,
  so use [`serve!`](@ref) and [`wait`](@ref Base.wait(::Server)) for that.

# Examples
A complete program. Save it as `hello.jl`, run `julia -t 4 hello.jl`, then
open `http://127.0.0.1:8080/`:

```julia
using Facil

serve("127.0.0.1", 8080) do req
    Response(StatusCodes.OK, "hello")
end
```

This is `docs/examples/hello.jl`, which the documentation build starts and
requests. See the [shutdown guide](@ref shutdown-guide) for signals.
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
