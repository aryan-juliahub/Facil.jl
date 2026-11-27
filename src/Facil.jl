"""
    Facil

An HTTP/1.1 server for Julia built on [facil.io](https://github.com/boazsegev/facil.io).

[`serve`](@ref) and [`serve!`](@ref) run a handler: a function that takes an
HttpTypes [`Request`](@ref) and returns a [`Response`](@ref). The same handler
can answer with a streamed response ([`stream`](@ref)), an event stream
([`sse`](@ref)), a file ([`sendfile`](@ref)) or a WebSocket
([`websocket`](@ref)). Facil also has pub/sub ([`publish`](@ref)), timers
([`every`](@ref)) and HTTPS ([`TLSConfig`](@ref)).

Facil re-exports every name of HttpTypes, so `using Facil` is all a server needs.

# Examples
```jldoctest
julia> using Facil

julia> import Downloads

julia> server = serve!(0) do req
           Response(StatusCodes.OK, "hello")
       end;

julia> String(take!(Downloads.download("http://127.0.0.1:\$(port(server))/", IOBuffer())))
"hello"

julia> close(server)
```
"""
module Facil

using Libdl
using OpenSSL_jll
using Preferences: @load_preference
import Scratch
using HttpTypes
import Sockets: send
import Dates

for name in names(HttpTypes)
    name === :HttpTypes || @eval export $name
end
export HttpTypes, serve, serve!, Server, every
export Buffer, Stream, Spool, Reject, RequestHead, BodyStream, body_stream, body_chunks
export TLSConfig, TLSError, reload!
export websocket, WebSocket, send, subscribe, unsubscribe, publish
export stream, ResponseStream, sse, SSEStream, write_event, last_event_id, sendfile, CompressOptions
export client_address, client_certificate, isconnected, on_disconnect
export query_params, query_param, parse_query, parse_form, decoded_path, percent_encode, percent_decode
export cookies, set_cookie!, delete_cookie!

include("libfjl.jl")
include("reactor.jl")
include("request.jl")
include("response.jl")
include("server.jl")
include("body.jl")
include("signals.jl")
include("async.jl")
include("timers.jl")
include("websockets.jl")
include("pubsub.jl")
include("tls.jl")
include("compress.jl")
include("streaming.jl")
include("sse.jl")
include("static.jl")
include("url.jl")
include("cookies.jl")

function __init__()
    load_libfjl()
    init_reactor()
    init_server()
    init_body()
    init_async()
    init_websockets()
    init_streaming()
    init_sse()
    init_static()
end

include("precompile.jl")

end
