struct CSlice
    ptr::Ptr{UInt8}
    len::Int64
end

struct CHeader
    code::Int32
    pad::Int32
    name::CSlice
    value::CSlice
end

struct CRequest
    method::CSlice
    path::CSlice
    query::CSlice
    body::CSlice
    version::Int32
    nheaders::Int32
    headers::Ptr{CHeader}
end

const VERSIONS = (Versions.HTTP_09, Versions.HTTP_10, Versions.HTTP_11, Versions.HTTP_2, Versions.HTTP_3)

function init_http_tables()
    names = [s for (_, s) in HttpTypes.STANDARD_HEADER_TABLE]
    lens = UInt8[sizeof(s) for s in names]
    ptrs = [pointer(s) for s in names]
    GC.@preserve names begin
        @ccall LIBFJL.fjl_http_init(ptrs::Ptr{Ptr{UInt8}}, lens::Ptr{UInt8}, length(names)::Cint)::Cint
    end
    for code in 100:999
        reason = something(canonical_reason(StatusCode(code)), "Unknown")
        @ccall LIBFJL.http_status_reason_set(code::Csize_t, reason::Ptr{UInt8}, sizeof(reason)::Csize_t)::Cvoid
    end
    nothing
end

"""
    read_request(h) -> Request{String}

Copies the request facil.io parsed on `h` into HttpTypes values, with the body
facil.io buffered. Throws an HttpTypes error when the method, target or a
header name is invalid. Internal: the server calls `read_request(srv, h)`,
which applies `before_body` and falls back to this method for requests
without a body.
"""
@noinline function read_request(h::Ptr{Cvoid})
    r = unsafe_load(@ccall LIBFJL.fjl_req_read(h::Ptr{Cvoid})::Ptr{CRequest})
    m = HttpMethod(r.method.ptr, r.method.len)
    u = HttpTypes.uri_from_target(r.path.ptr, r.path.len, r.query.ptr, r.query.len)
    v = 1 <= r.version <= 5 ? @inbounds(VERSIONS[r.version]) : Versions.HTTP_11
    n = Int(r.nheaders)
    hm = HeaderMap{HeaderValue}(n)
    for i in 1:n
        c = unsafe_load(r.headers, i)
        name = c.code != 0 ? @inbounds(HttpTypes.standard_header(c.code)) : HeaderName(c.name.ptr, c.name.len)
        append!(hm, name, HttpTypes.unchecked(HeaderValue, c.value.ptr, c.value.len))
    end
    body = r.body.len > 0 ? unsafe_string(r.body.ptr, r.body.len) : ""
    Request(m, u, v, hm, Extensions(), body)
end

# ---- the client of a request

struct CPeer
    ip::NTuple{48,UInt8}
    ip_len::Int32
    port::Int32
    tls::Int32
    pad::Int32
    cert::Ptr{UInt8}
    cert_len::Int64
end

const CONN_INLINE, CONN_RUNNING, CONN_PAUSED, CONN_DONE = 0, 1, 2, 3

# What Facil knows about the connection a request arrived on, kept in the
# request's extensions. `a` is the paused request while `phase == CONN_PAUSED`;
# every field below `locked` is guarded by it.
mutable struct Connection
    const ip::NTuple{48,UInt8}
    const ip_len::Int
    const port::Int
    const cert::Union{Nothing,String}
    @atomic locked::Bool
    phase::Int
    a::Ptr{Cvoid}
    id::UInt64
    watched::Bool
    gone::Bool
    fired::Bool
    callbacks::Union{Nothing,Vector{Any}}
end

# Reads the client of `h` (reactor thread, `h` valid); `nothing` for an offline request.
function read_connection(h::Ptr{Cvoid}, phase::Int)
    r = Ref{CPeer}()
    ok = @ccall LIBFJL.fjl_req_peer(h::Ptr{Cvoid}, r::Ptr{CPeer}, 1::Cint)::Cint
    ok == 0 || return nothing
    p = r[]
    cert = nothing
    if p.cert != C_NULL
        cert = unsafe_string(p.cert, p.cert_len)
        @ccall LIBFJL.fjl_free(p.cert::Ptr{UInt8})::Cvoid
    end
    Connection(p.ip, Int(p.ip_len), Int(p.port), cert, false, phase, C_NULL, UInt64(0), false, false, false, nothing)
end

function conn_lock(c::Connection)
    ccall(:jl_sigatomic_begin, Cvoid, ())
    while (@atomicreplace c.locked false => true).success == false
        ccall(:jl_cpu_pause, Cvoid, ())
        GC.safepoint()
    end
    nothing
end

function conn_unlock(c::Connection)
    @atomic :release c.locked = false
    ccall(:jl_sigatomic_end, Cvoid, ())
    nothing
end

conn_ip(c::Connection) = String(collect(c.ip[1:c.ip_len]))

# The request an inline handler is running, per thread, with its handle.
const INLINE_SLOTS = 512
const INLINE_REQ = Vector{Any}(nothing, INLINE_SLOTS)
const INLINE_H = fill(C_NULL, INLINE_SLOTS)

@inline function inline_begin(req, h::Ptr{Cvoid})
    t = Threads.threadid()
    t <= INLINE_SLOTS || return nothing
    @inbounds INLINE_H[t] = h
    @inbounds INLINE_REQ[t] = req
    nothing
end

@inline function inline_end()
    t = Threads.threadid()
    t <= INLINE_SLOTS || return nothing
    @inbounds INLINE_REQ[t] = nothing
    nothing
end

# The connection of `req`, read now when an inline handler is running it on
# this thread; `nothing` when Facil has none for it.
function connection(req::Request)
    c = get(extensions(req), Connection, nothing)
    c === nothing || return c
    t = Threads.threadid()
    (t <= INLINE_SLOTS && @inbounds(INLINE_REQ[t]) === req) || return nothing
    c = read_connection(@inbounds(INLINE_H[t]), CONN_INLINE)
    c === nothing || insert!(extensions(req), c)
    c
end

# A stream, event stream or WebSocket uses its request after an inline handler
# returned, so the connection is read while the handler's thread still has it.
function keep_connection!(req::Request, @nospecialize(res))
    if res isa WebSocketUpgrade || (res isa Response && (b = getfield(res, :body); b isa StreamBody || b isa SSEBody))
        connection(req)
    end
    nothing
end

"""
    client_address(req::Request) -> Union{NamedTuple{(:ip, :port)},Nothing}

The address of the client that sent `req`: `(ip = "203.0.113.7", port = 51234)`.

`ip` is the textual IPv4 or IPv6 address (`"::1"`, or `"::ffff:127.0.0.1"`
for an IPv4 client of a server listening on `"::"`), `port` the client's TCP
port. It is the peer of the TCP connection, so behind a proxy it is the
proxy's address; read `forwarded` or `x-forwarded-for` for the original
client, if you trust the proxy.

Works for HTTP and HTTPS, in inline and task handlers, and in handlers that
answer with [`websocket`](@ref), [`sse`](@ref) or [`stream`](@ref).

# Returns
`nothing` when Facil has no connection for `req`: a request built by hand,
or one whose inline handler returned a plain response without asking (task
handlers, and inline handlers that answer with a stream, an event stream or
a WebSocket, have it captured; another inline handler that keeps the request
asks once while it runs).

# Examples
```jldoctest
julia> using Facil

julia> import Downloads

julia> server = serve!(0) do req
           c = client_address(req)
           c.ip
       end;

julia> String(take!(Downloads.download("http://127.0.0.1:\$(port(server))/", IOBuffer())))
"127.0.0.1"

julia> close(server)

julia> client_address(Request(Methods.GET, "/")) === nothing
true
```

See also [`client_certificate`](@ref).
"""
function client_address(req::Request)
    c = connection(req)
    c === nothing ? nothing : (ip = conn_ip(c), port = c.port)
end

"""
    client_certificate(req::Request) -> Union{String,Nothing}

The certificate the client presented over mutual TLS, as PEM text
(`-----BEGIN CERTIFICATE-----` ...), or `nothing`.

A client only sends a certificate when the server asks for one, which a
[`TLSConfig`](@ref) with `client_ca` does. The handshake has already checked
it against `client_ca`, so a certificate returned here is one those CAs
issued. With `require_client_cert = false` a client may connect without one;
`nothing` then.

# Returns
`nothing` for plain HTTP, for a TLS client without a certificate, and in the
cases where [`client_address`](@ref) is `nothing`.

# Examples
```julia
serve!(8443; tls = TLSConfig(cert = "server.pem", key = "server.key",
                             client_ca = "clients-ca.pem")) do req
    pem = client_certificate(req)
    pem === nothing ? Response(StatusCodes.UNAUTHORIZED) : "hello, client"
end
```
"""
function client_certificate(req::Request)
    c = connection(req)
    c === nothing ? nothing : c.cert
end

# The probe a FIN needs is an interim reply, which only HTTP/1.1 allows and an
# upgrade handshake does not expect.
probe_ok(req::Request) = version(req) == Versions.HTTP_11 && !haskey(headers(req), header.UPGRADE)

const WATCHED = Dict{UInt64,Connection}()
const WATCHED_LOCK = Threads.SpinLock()

async_watch(a::Ptr{Cvoid}, notify::Bool, probe::Bool) =
    @ccall LIBFJL.fjl_async_watch(a::Ptr{Cvoid}, notify::Cint, probe::Cint)::Cint
async_client(a::Ptr{Cvoid}) = @ccall LIBFJL.fjl_async_client(a::Ptr{Cvoid})::Cint

# Starts the client watch of a paused request (lock held).
function watch!(c::Connection, notify::Bool, probe::Bool)
    gone = async_watch(c.a, notify, probe) == 2
    c.watched = true
    if notify
        lock_sigatomic(WATCHED_LOCK)
        WATCHED[c.id] = c
        unlock_sigatomic(WATCHED_LOCK)
    end
    gone
end

# Marks the client gone; returns the callbacks to run (lock held).
function mark_gone!(c::Connection)
    c.gone = true
    c.fired && return nothing
    c.fired = true
    cbs = c.callbacks
    c.callbacks = nothing
    cbs
end

function run_callbacks(cbs)
    cbs === nothing && return nothing
    for f in cbs
        Threads.@spawn :default try
            f()
        catch e
            log_error("an on_disconnect callback", e, catch_backtrace())
        end
    end
    nothing
end

"""
    isconnected(req::Request) -> Bool

Whether the client that sent `req` still has its connection open, as far as
Facil can tell. For a task handler doing long work, to stop early when nobody
waits for the answer.

The first call starts watching the connection. The value turns `false` within
about half a second of the client closing its connection or resetting it,
while the handler runs.

# What counts as gone
- A reset, or a connection that the server closed (for example by
  [`close(server)`](@ref Base.close(::Server))).
- A client that closed its connection. TCP cannot tell that apart from a
  client that only stopped sending (a half-close) and still reads the reply,
  so for an HTTP/1.1 request Facil sends one `100 Continue` interim
  response, which every HTTP/1.1 client skips: a client that closed answers
  it with a reset, one that half-closed reads it and stays connected. HTTP/1.0
  requests and upgrade requests (WebSocket) cannot be sent an interim
  response, so for them only a reset counts.

# Returns
- In a task handler, the state above. After the handler has returned it no
  longer changes.
- `true` in an inline handler (`inline = true`, or Julia with one thread):
  the reactor runs it and cannot watch the connection meanwhile. Also `true`
  for a request Facil did not receive (built by hand, as in a unit test).

# Examples
```julia
serve!(8080) do req
    for step in 1:100
        isconnected(req) || return Response(StatusCodes.SERVICE_UNAVAILABLE)
        do_work(step)
    end
    "done"
end
```

See also [`on_disconnect`](@ref).
"""
function isconnected(req::Request)
    c = get(extensions(req), Connection, nothing)
    c === nothing && return true
    cbs = nothing
    conn_lock(c)
    if c.phase == CONN_PAUSED && !c.gone
        gone = c.watched ? async_client(c.a) == 2 : watch!(c, false, probe_ok(req))
        gone && (cbs = mark_gone!(c))
    end
    alive = !c.gone
    conn_unlock(c)
    run_callbacks(cbs)
    alive
end

"""
    on_disconnect(f, req::Request)

Run `f()` once if the client of `req` goes away while its task handler runs.

`f` runs on a Julia task of its own (never on the reactor thread), so it may
block; it typically notifies the handler, for example by closing a `Channel`
or setting a flag the handler checks. What counts as going away is described
under [`isconnected`](@ref); `f` runs within about half a second of it.

# Notes
- `f` runs at most once. If the client is already gone, it is scheduled at
  once. If the handler returns first, it never runs.
- Several callbacks may be registered; each runs once.
- An error thrown by `f` is logged to stderr.
- Inline handlers: does nothing, as the reactor that runs them cannot watch
  the connection meanwhile.
- The response the handler returns is still sent whatever happened; to a
  client that is gone it is discarded.

# Examples
```julia
serve!(8080) do req
    cancelled = Threads.Atomic{Bool}(false)
    on_disconnect(() -> cancelled[] = true, req)
    result = long_computation(; stop = () -> cancelled[])
    cancelled[] ? Response(StatusCodes.SERVICE_UNAVAILABLE) : result
end
```
"""
function on_disconnect(f, req::Request)
    c = get(extensions(req), Connection, nothing)
    c === nothing && return nothing
    cbs = nothing
    conn_lock(c)
    if c.phase == CONN_RUNNING || c.phase == CONN_PAUSED
        if c.fired
            cbs = Any[f]
        else
            c.callbacks === nothing && (c.callbacks = Any[])
            push!(c.callbacks, f)
            if c.phase == CONN_PAUSED && watch!(c, true, probe_ok(req))
                cbs = mark_gone!(c)
            end
        end
    end
    conn_unlock(c)
    run_callbacks(cbs)
    nothing
end

# A paused request's connection: from now on it can be watched.
function conn_paused!(c::Connection, req::Request, a::Ptr{Cvoid}, id::UInt64)
    cbs = nothing
    conn_lock(c)
    if c.phase == CONN_RUNNING
        c.phase, c.a, c.id = CONN_PAUSED, a, id
        if !c.fired && c.callbacks !== nothing && watch!(c, true, probe_ok(req))
            cbs = mark_gone!(c)
        end
    end
    conn_unlock(c)
    run_callbacks(cbs)
    nothing
end

# The handler returned: the state is final and `a` is no longer touched.
function conn_done!(c::Connection)
    conn_lock(c)
    if c.phase == CONN_PAUSED && c.watched && !c.gone && async_client(c.a) == 2
        c.gone = true
    end
    id = c.phase == CONN_PAUSED && c.watched ? c.id : UInt64(0)
    c.phase, c.a, c.callbacks = CONN_DONE, C_NULL, nothing
    conn_unlock(c)
    if id != 0
        lock_sigatomic(WATCHED_LOCK)
        delete!(WATCHED, id)
        unlock_sigatomic(WATCHED_LOCK)
    end
    nothing
end

# The body of a streamed request stopped because the client left.
function conn_aborted!(c::Connection)
    conn_lock(c)
    cbs = c.phase == CONN_RUNNING ? mark_gone!(c) : nothing
    conn_unlock(c)
    run_callbacks(cbs)
    nothing
end

# Reactor callback: the watch found the client of request `id` gone.
function on_client_gone(id::UInt64)
    try
        lock_sigatomic(WATCHED_LOCK)
        c = pop!(WATCHED, id, nothing)
        unlock_sigatomic(WATCHED_LOCK)
        c === nothing && return nothing
        conn_lock(c)
        cbs = c.phase == CONN_PAUSED && c.id == id ? mark_gone!(c) : nothing
        conn_unlock(c)
        run_callbacks(cbs)
    catch e
        callback_error("a client that went away", e, catch_backtrace())
    end
    nothing
end
