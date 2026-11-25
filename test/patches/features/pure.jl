# Pure ccall/@cfunction: no shim symbols. usage: julia -t 4 pure.jl <lib> <port>
const lib = ARGS[1]; const PORT = ARGS[2]
struct HttpSettings
    on_request::Ptr{Cvoid}; on_upgrade::Ptr{Cvoid}; on_response::Ptr{Cvoid}; on_finish::Ptr{Cvoid}
    udata::Ptr{Cvoid}; public_folder::Ptr{Cchar}; public_folder_length::Csize_t
    max_header_size::Csize_t; max_body_size::Csize_t; max_clients::Int; tls::Ptr{Cvoid}
    reserved1::Int; reserved2::Int; reserved3::Int; ws_max_msg_size::Csize_t
    timeout::UInt8; ws_timeout::UInt8; log::UInt8; is_client::UInt8
end
struct FioStartArgs; threads::Int16; workers::Int16; end
struct FioStr; capa::Csize_t; len::Csize_t; data::Ptr{UInt8}; end
FioStr(p::Ptr{UInt8}, n) = FioStr(0, n, p)
const NOSTR = FioStr(0, 0, C_NULL)
struct WsSettings; on_message::Ptr{Cvoid}; on_open::Ptr{Cvoid}; on_ready::Ptr{Cvoid}; on_shutdown::Ptr{Cvoid}; on_close::Ptr{Cvoid}; udata::Ptr{Cvoid}; end
struct WsSubscribe; ws::Ptr{Cvoid}; channel::FioStr; on_message::Ptr{Cvoid}; on_unsubscribe::Ptr{Cvoid}; udata::Ptr{Cvoid}; match::Ptr{Cvoid}; bits::UInt8; end
struct PublishArgs; engine::Ptr{Cvoid}; filter::Int32; channel::FioStr; message::FioStr; is_json::UInt8; end
struct SseSettings; on_open::Ptr{Cvoid}; on_ready::Ptr{Cvoid}; on_shutdown::Ptr{Cvoid}; on_close::Ptr{Cvoid}; udata::Ptr{Cvoid}; end
struct SseWrite; id::FioStr; event::FioStr; data::FioStr; retry::Int; end
struct WriteArgs; buffer::Ptr{Cvoid}; dealloc::Ptr{Cvoid}; length::UInt; offset::UInt; bits::UInt8; end
println(stderr, "julia sizeof: FioStr=$(sizeof(FioStr)) WsSettings=$(sizeof(WsSettings)) SseSettings=$(sizeof(SseSettings)) SseWrite=$(sizeof(SseWrite)) PublishArgs=$(sizeof(PublishArgs)) WsSubscribe=$(sizeof(WsSubscribe)) WriteArgs=$(sizeof(WriteArgs)) HttpSettings=$(sizeof(HttpSettings))")

function ws_msg(ws::Ptr{Cvoid}, msg::FioStr, is_text::UInt8)
    ccall((:websocket_write, lib), Cint, (Ptr{Cvoid}, FioStr, UInt8), ws, msg, is_text); nothing
end
function ws_open(ws::Ptr{Cvoid})
    ch = "room"
    GC.@preserve ch ccall((:websocket_subscribe, lib), UInt, (WsSubscribe,), WsSubscribe(ws, FioStr(pointer(ch), 4), C_NULL, C_NULL, C_NULL, C_NULL, 0))
    nothing
end
ws_close(uuid::Int, ::Ptr{Cvoid}) = (println(stderr, "pure on_close uuid=$uuid"); nothing)
function sse_open(sse::Ptr{Cvoid})
    for i in 1:3
        m = "pure event $i"
        GC.@preserve m ccall((:http_sse_write, lib), Cint, (Ptr{Cvoid}, SseWrite), sse, SseWrite(NOSTR, NOSTR, FioStr(pointer(m), sizeof(m)), 0))
    end
    ccall((:http_sse_close, lib), Cint, (Ptr{Cvoid},), sse); nothing
end
function on_upgrade(h::Ptr{Cvoid}, proto::Ptr{UInt8}, len::Csize_t)
    if unsafe_string(proto, len) == "websocket"
        ccall((:http_upgrade2ws, lib), Cint, (Ptr{Cvoid}, WsSettings), h, WsSettings(ws_msg_c[], ws_open_c[], C_NULL, C_NULL, ws_close_c[], C_NULL))
    else
        ccall((:http_upgrade2sse, lib), Cint, (Ptr{Cvoid}, SseSettings), h, SseSettings(sse_open_c[], C_NULL, C_NULL, C_NULL, C_NULL))
    end
    nothing
end
function rawwrite(uuid, s)
    p = Libc.malloc(sizeof(s)); unsafe_copyto!(Ptr{UInt8}(p), pointer(s), sizeof(s))
    ccall((:fio_write2_fn, lib), Cssize_t, (Int, WriteArgs), uuid, WriteArgs(p, cglobal(:free), sizeof(s), 0, 0))
end
# http_s: path is the FIOBJ at byte offset 72; a FIOBJ string is not readable without inline helpers,
# so this script routes on nothing but the upgrade/hijack calls.
function on_request(h::Ptr{Cvoid})
    uuid = ccall((:http_hijack, lib), Int, (Ptr{Cvoid}, Ptr{Cvoid}), h, C_NULL)
    errormonitor(Threads.@spawn begin
        m = "published by pure ccall"; ch = "room"
        GC.@preserve m ch ccall((:fio_publish, lib), Cvoid, (PublishArgs,), PublishArgs(C_NULL, 0, FioStr(pointer(ch), 4), FioStr(pointer(m), sizeof(m)), 0))
        rawwrite($uuid, "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 12\r\n\r\npure hijack\n")
        ccall((:fio_close, lib), Cvoid, (Int,), $uuid)
    end)
    nothing
end
const ws_msg_c = Ref{Ptr{Cvoid}}(); const ws_open_c = Ref{Ptr{Cvoid}}(); const ws_close_c = Ref{Ptr{Cvoid}}(); const sse_open_c = Ref{Ptr{Cvoid}}()
function main()
    ws_msg_c[] = @cfunction(ws_msg, Cvoid, (Ptr{Cvoid}, FioStr, UInt8)); ws_open_c[] = @cfunction(ws_open, Cvoid, (Ptr{Cvoid},))
    ws_close_c[] = @cfunction(ws_close, Cvoid, (Int, Ptr{Cvoid})); sse_open_c[] = @cfunction(sse_open, Cvoid, (Ptr{Cvoid},))
    s = HttpSettings(@cfunction(on_request, Cvoid, (Ptr{Cvoid},)), @cfunction(on_upgrade, Cvoid, (Ptr{Cvoid}, Ptr{UInt8}, Csize_t)),
                     C_NULL, C_NULL, C_NULL, C_NULL, 0, 0, 0, 0, C_NULL, 0, 0, 0, 0, 0, 0, 0, 0)
    ccall((:http_listen, lib), Int, (Cstring, Ptr{Cchar}, HttpSettings), PORT, C_NULL, s) < 0 && error("listen")
    wait(Threads.@spawn @ccall gc_safe=true lib.fio_start(FioStartArgs(1, 1)::FioStartArgs)::Cvoid)
end
main()
