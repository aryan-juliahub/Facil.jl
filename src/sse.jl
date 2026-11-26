# Server-sent events: facil.io's SSE upgrade on the reactor, then events written
# by uuid from the stream's own task. The SSE handle is duplicated before it
# leaves the reactor and released when the stream is done with it.

"""
    SSEStream

An open event stream. [`sse`](@ref) passes one to your function.

| Call | Effect |
|:--|:--|
| [`write_event(s; data, event, id, retry)`](@ref write_event) | send one event |
| [`Facil.write_comment(s, text)`](@ref) | send a comment line (a keep-alive) |
| [`last_event_id(s)`](@ref last_event_id) | the `Last-Event-ID` the client reconnected with, or `nothing` |
| `isopen(s)` | `false` once the client has gone or the stream is closed |
| `wait(s)` | block until the client has gone or the stream is closed |
| [`close(s)`](@ref Base.close(::SSEStream)) | close the connection; done for you when your function returns |

`write_event`, `Facil.write_comment` and `close` may be called from any task
or thread, so another part of your program can keep the `SSEStream` and push
events to it while your function waits in `wait(s)`.
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

The value of the `Last-Event-ID` request header, or `nothing` if the client
sent none.

A browser's `EventSource` reconnects by itself after a dropped connection and
sends the `id` of the last event it received. Use it to resume where the client
left off.

# Examples
```jldoctest
julia> using Facil

julia> import Downloads

julia> server = serve!(0) do req
           sse(req) do s
               write_event(s, "resuming after " * something(last_event_id(s), "nothing"))
           end
       end;

julia> url = "http://127.0.0.1:\$(port(server))/";

julia> print(String(take!(Downloads.download(url, IOBuffer(); headers = ["Last-Event-ID" => "41"]))))
data: resuming after 41

julia> close(server)
```
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
    write_event(s::SSEStream, data) -> Bool

Send one event on an event stream.

# Arguments
- `data`: the payload. Anything `string` accepts, or a byte vector holding
  UTF-8. Line breaks are allowed: each line becomes its own `data:` line and
  the client joins them with `\\n`.
- `event`: the event type, for `addEventListener(type, ...)` in a browser.
  Without it the client fires `message`.
- `id`: the event id. The client sends the last one back as `Last-Event-ID`
  when it reconnects; see [`last_event_id`](@ref).
- `retry::Integer`: how many milliseconds the client should wait before
  reconnecting.

# Returns
`true` if the event was queued, `false` if the client has gone or the stream
is closed (nothing is sent then, and nothing is thrown).

# Throws
- `ArgumentError` if all four are `nothing`, or if `event` or `id` contains a
  line break.

# Notes
Called on a task, it blocks while more than the stream's `high_water` bytes
wait for a slow client. It may be called from any thread.

# Examples
```jldoctest
julia> using Facil

julia> import Downloads

julia> server = serve!(0) do req
           sse(req) do s
               write_event(s; event = "price", data = "42.10", id = 7)
               write_event(s, "two\\nlines")
           end
       end;

julia> print(String(take!(Downloads.download("http://127.0.0.1:\$(port(server))/", IOBuffer()))))
event: price
id: 7
data: 42.10

data: two
data: lines

julia> close(server)
```
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
    Facil.write_comment(s::SSEStream, text = "") -> Bool

Send a comment line (`: text`) on an event stream. Clients ignore comments, so
this is the usual keep-alive for streams that are quiet for long stretches:
proxies and load balancers close connections that carry no bytes.

Returns `true` if it was queued, `false` if the client has gone. Throws
`ArgumentError` if `text` contains a line break.
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

Close an event stream and its connection.

[`sse`](@ref) calls this when your function returns. Call it from elsewhere to
end a stream whose function is blocked in `wait(s)`. Closing twice does
nothing. A browser `EventSource` treats the close as a dropped connection and
reconnects; answer the reconnect with status 204 to make it stop.
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

Answer `req` with an event stream (server-sent events, `text/event-stream`).

Return the result from your handler. Facil sends the response head, then calls
`f(s)` with an [`SSEStream`](@ref) on a worker task. The connection stays open
until `f` returns or the client goes away.

# Arguments
- `f`: `f(s::SSEStream)`. It runs on a task whatever the server's `inline`
  setting, so it may block, sleep and wait.
- `req`: the request being answered. Its `Last-Event-ID` header becomes
  [`last_event_id(s)`](@ref last_event_id).

# Keywords
- `headers = []`: extra response headers, as `name => value` pairs or a
  [`HeaderMap`](@ref) (for example `access-control-allow-origin`).
- `high_water::Integer = 1 MiB`: [`write_event`](@ref) blocks while more than
  this many bytes wait for the client.

# Returns
A [`Response`](@ref) to return from the handler.

# Throws
- `ArgumentError` if `high_water` is not positive.

# Notes
- The connection belongs to the event stream from then on: it serves no
  further HTTP requests and is closed when `f` returns.
- Facil does not check the request's `Accept` header. Decide in your handler
  which requests get an event stream, by path or by `Accept: text/event-stream`.
- If `f` throws, the error is logged and the stream is closed.
- The response is never compressed.
- A stream that sends nothing for longer than a proxy's idle timeout gets cut
  off; send [`Facil.write_comment`](@ref) every 15 to 30 seconds.

# Examples
```jldoctest
julia> using Facil

julia> import Downloads

julia> server = serve!(0) do req
           sse(req) do s
               for n in 1:3
                   write_event(s; data = "tick \$n", id = n)
                   Facil.sleep(0.01)
               end
           end
       end;

julia> print(String(take!(Downloads.download("http://127.0.0.1:\$(port(server))/", IOBuffer()))))
id: 1
data: tick 1

id: 2
data: tick 2

id: 3
data: tick 3

julia> close(server)
```

See the [server-sent events guide](@ref sse-guide).
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
