"""
    Facil

An HTTP/1.1 server built on facil.io: [`serve`](@ref) and [`serve!`](@ref) run a
handler that takes an HttpTypes `Request` and returns a `Response`. Also
WebSockets, server-sent events, streaming, static files, pub/sub, timers and TLS.
Re-exports HttpTypes.
"""
module Facil

using Libdl
using OpenSSL_jll
using Preferences: @load_preference
import Scratch
using HttpTypes
import Sockets: send

for name in names(HttpTypes)
    name === :HttpTypes || @eval export $name
end
export HttpTypes, serve, serve!, Server, every
export Buffer, Stream, Spool, Reject, RequestHead, BodyStream, body_stream, body_chunks
export TLSConfig, TLSError, reload!
export websocket, WebSocket, send, subscribe, unsubscribe, publish
export stream, ResponseStream, sse, SSEStream, write_event, last_event_id, sendfile, CompressOptions

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
