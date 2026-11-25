# Server-sent events: facil.io's SSE upgrade on the reactor, then events written
# by uuid from the stream's own task. The SSE handle is duplicated before it
# leaves the reactor and released when the stream is done with it.

"""
    SSEStream

An open event stream, handed to the function given to [`sse`](@ref).
[`write_event`](@ref) sends an event, `isopen` turns false once the client has
gone, `wait(s)` blocks until then, `close(s)` ends the stream, and
[`last_event_id`](@ref) is the client's `Last-Event-ID` (or `nothing`).
"""
mutable struct SSEStream
    const last_event_id::Union{Nothing,String}
    const high_water::Int
    const drained::Base.Event
    const lock::ReentrantLock
    handle::Ptr{Cvoid}
    uuid::Int
    tls::Bool
    key::UInt
    @atomic gone::Bool
    @atomic closed::Bool
    const done::Base.Event
end

SSEStream(last_id, high_water::Int) =
    SSEStream(last_id, high_water, Base.Event(true), ReentrantLock(), C_NULL, -1, false, UInt(0), false, false, Base.Event())

mark_gone!(s::SSEStream) = (@atomic s.gone = true; notify(s.drained); notify(s.done); nothing)

Base.isopen(s::SSEStream) = !(@atomic s.gone) && !(@atomic s.closed)
Base.wait(s::SSEStream) = (wait(s.done); nothing)
Base.show(io::IO, s::SSEStream) = print(io, "Facil.SSEStream(", isopen(s) ? "open" : "closed", ")")

"""
    last_event_id(s::SSEStream) -> Union{Nothing,String}

The `Last-Event-ID` header the client reconnected with.
"""
last_event_id(s::SSEStream) = s.last_event_id

function check_field(name, v::AbstractString)
    (occursin('\n', v) || occursin('\r', v)) && throw(ArgumentError("SSE $name must not contain a line break"))
    v
end

function sse_line!(io::IOBuffer, field::String, v::AbstractString)
    write(io, field, ": ", v, '\n')
end

"""
    write_event(s::SSEStream; data = nothing, event = nothing, id = nothing, retry = nothing) -> Bool
    write_event(s::SSEStream, data)

Sends one event. `data` may span lines (each becomes a `data:` line); `event`
and `id` must be single lines; `retry` is the client's reconnection delay in
milliseconds. Returns `false` once the client has gone. On a task the call
waits while more than the stream's `high_water` bytes are queued.
"""
function write_event(s::SSEStream; data = nothing, event = nothing, id = nothing, retry::Union{Nothing,Integer} = nothing)
    io = IOBuffer()
    event === nothing || sse_line!(io, "event", check_field("event", string(event)))
    id === nothing || sse_line!(io, "id", check_field("id", string(id)))
    retry === nothing || sse_line!(io, "retry", string(Int(retry)))
    if data !== nothing
        d = data isa AbstractVector{UInt8} ? String(copy(data)) : string(data)
        for line in eachsplit(replace(d, "\r\n" => "\n", '\r' => '\n'), '\n')
            sse_line!(io, "data", line)
        end
    end
    position(io) == 0 && throw(ArgumentError("an SSE event needs data, event, id or retry"))
    write(io, '\n')
    send_sse(s, take!(io))
end
write_event(s::SSEStream, data) = write_event(s; data)

"""
    Facil.write_comment(s::SSEStream, text = "")

Sends a comment line (`: text`), which clients ignore; useful as a keep-alive.
"""
write_comment(s::SSEStream, text::AbstractString = "") = send_sse(s, Vector{UInt8}(codeunits(string(": ", check_field("comment", text), "\n\n"))))

function send_sse(s::SSEStream, buf::Vector{UInt8})
    isopen(s) || return false
    on_reactor = fjl_on_reactor()
    mode = s.tls && !on_reactor ? FIO_LAZY : FIO_FLUSH
    r = queue_bytes(s.uuid, buf, mode | SW_WAKE)
    if r < 0
        @atomic s.gone = true
        return false
    end
    (!on_reactor && r > s.high_water) && wait_drain(s)
    true
end

"""
    close(s::SSEStream)

Closes the connection. Called for you when the function given to [`sse`](@ref) returns.
"""
function Base.close(s::SSEStream)
    _, ok = @atomicreplace s.closed false => true
    ok || return nothing
    lock(s.lock) do
        if s.handle != C_NULL
            @gcsafe_ccall LIBFJL.fjl_sse_close(s.handle::Ptr{Cvoid})::Cint
            @gcsafe_ccall LIBFJL.fjl_sse_free(s.handle::Ptr{Cvoid})::Cvoid
            s.handle = C_NULL
        end
    end
    s.key == 0 || unregister_stream!(s.key)
    notify(s.done)
    nothing
end

"Body of an event-stream response; see [`sse`](@ref)."
struct SSEBody{F}
    f::F
    last_event_id::Union{Nothing,String}
    high_water::Int
end

const LAST_EVENT_ID = hn"last-event-id"

"""
    sse(f, req; headers = [], high_water = 1 MiB) -> Response

Answers `req` with an event stream (`text/event-stream`); the handler returns
it. `f(s::SSEStream)` runs on its own task and the connection stays open until
it returns or the client goes away:

```julia
serve!(8080) do req
    sse(req) do s
        n = something(tryparse(Int, something(last_event_id(s), "0")), 0)
        while isopen(s)
            write_event(s; data = "tick \$n", id = n)
            n += 1
            Facil.sleep(1)
        end
    end
end
```

The connection is no longer HTTP afterwards (no further requests on it).
Requests with `Accept: text/event-stream` reach the handler like any other.
"""
function sse(f, req; headers = HeaderMap{HeaderValue}(), high_water::Integer = 1024 * 1024)
    high_water > 0 || throw(ArgumentError("high_water must be positive"))
    v = get(HttpTypes.headers(req), LAST_EVENT_ID, nothing)
    Response(StatusCodes.OK, SSEBody(f, v === nothing ? nothing : as_str(v), Int(high_water)); headers)
end

compress_response(req, res::Response{<:SSEBody}, ::CompressOptions) = res

const ON_SSE_CLOSE = Ref{Ptr{Cvoid}}(C_NULL)

on_sse_close(udata::Ptr{Cvoid}) = on_stream_gone(udata)

@noinline function respond(h::Ptr{Cvoid}, res::Response{<:SSEBody})
    b = res.body
    write_headers(h, res.headers)
    s = SSEStream(b.last_event_id, b.high_water)
    s.key = register_stream!(s)
    uuid, tls = Ref{Int}(-1), Ref{Cint}(0)
    p = @ccall LIBFJL.fjl_sse_upgrade(h::Ptr{Cvoid}, Ptr{Cvoid}(s.key)::Ptr{Cvoid}, ON_SSE_CLOSE[]::Ptr{Cvoid},
                                      uuid::Ptr{Int}, tls::Ptr{Cint})::Ptr{Cvoid}
    s.handle, s.uuid, s.tls = p, uuid[], tls[] != 0
    if p == C_NULL || uuid[] == -1
        mark_gone!(s)
        close(s)
        return nothing
    end
    spawn_body(h, () -> run_sse(b.f, s))
    nothing
end

function run_sse(f, s::SSEStream)
    try
        f(s)
    catch e
        log_error("an SSE handler", e, catch_backtrace())
    finally
        close(s)
    end
    nothing
end

function init_sse()
    ON_SSE_CLOSE[] = @cfunction(on_sse_close, Cvoid, (Ptr{Cvoid},))
    nothing
end
