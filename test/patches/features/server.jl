# usage: julia -t 4 server.jl <lib> <port> [maxbody_mb]
using SHA
const lib = ARGS[1]
const PORT = ARGS[2]
const MAXBODY = length(ARGS) >= 3 ? parse(Int, ARGS[3]) : 64
const HERE = @__DIR__

struct HttpSettings
    on_request::Ptr{Cvoid}; on_upgrade::Ptr{Cvoid}; on_response::Ptr{Cvoid}; on_finish::Ptr{Cvoid}
    udata::Ptr{Cvoid}; public_folder::Ptr{Cchar}; public_folder_length::Csize_t
    max_header_size::Csize_t; max_body_size::Csize_t; max_clients::Int; tls::Ptr{Cvoid}
    reserved1::Int; reserved2::Int; reserved3::Int; ws_max_msg_size::Csize_t
    timeout::UInt8; ws_timeout::UInt8; log::UInt8; is_client::UInt8
end
struct FioStartArgs; threads::Int16; workers::Int16; end

for f in (:shim_path, :shim_method, :shim_query)
    @eval function getstr(::Val{$(QuoteNode(f))}, h)
        len = Ref{Csize_t}(0)
        p = ccall(($(QuoteNode(f)), lib), Ptr{UInt8}, (Ptr{Cvoid}, Ref{Csize_t}), h, len)
        p == C_NULL ? "" : unsafe_string(p, len[])
    end
end
getstr(f::Symbol, h) = getstr(Val(f), h)
function header(h, name)
    len = Ref{Csize_t}(0)
    p = ccall((:shim_header, lib), Ptr{UInt8}, (Ptr{Cvoid}, Cstring, Csize_t, Ref{Csize_t}), h, name, sizeof(name), len)
    p == C_NULL ? nothing : unsafe_string(p, len[])
end
send(h, s) = ccall((:http_send_body, lib), Cint, (Ptr{Cvoid}, Ptr{UInt8}, Csize_t), h, s, sizeof(s))
rawwrite(uuid, s) = ccall((:shim_write_copy, lib), Cssize_t, (Int, Ptr{UInt8}, Csize_t), uuid, s, sizeof(s))

const closes = Threads.Atomic{Int}(0)
const opens = Threads.Atomic{Int}(0)
const sse_closes = Threads.Atomic{Int}(0)
const timer_calls = Threads.Atomic{Int}(0)
const timer_done = Threads.Atomic{Int}(0)
const timer_t0 = Ref(0.0); const timer_tlast = Ref(0.0)
const conns = Set{Int}(); const conns_lock = ReentrantLock()
const cb_tids = Set{Int}()

function ws_open(ws::Ptr{Cvoid})
    Threads.atomic_add!(opens, 1)
    uuid = ccall((:websocket_uuid, lib), Int, (Ptr{Cvoid},), ws)
    lock(conns_lock) do; push!(conns, uuid); push!(cb_tids, Threads.threadid()); end
    ccall((:shim_ws_subscribe, lib), UInt, (Ptr{Cvoid}, Cstring, Csize_t), ws, "room", 4)
    nothing
end
function ws_close(uuid::Int, udata::Ptr{Cvoid})
    Threads.atomic_add!(closes, 1)
    lock(conns_lock) do; delete!(conns, uuid); end
    nothing
end
function ws_msg(ws::Ptr{Cvoid}, data::Ptr{UInt8}, len::Csize_t, is_text::Cint)
    if is_text == 1 && len < 64
        s = unsafe_string(data, len)
        if s == "push-me"
            uuid = ccall((:websocket_uuid, lib), Int, (Ptr{Cvoid},), ws)
            errormonitor(Threads.@spawn begin
                sleep(0.05)
                m = "pushed from julia thread $(Threads.threadid())"
                ccall((:shim_ws_send_uuid, lib), Cvoid, (Int, Ptr{UInt8}, Csize_t, Cint), $uuid, m, sizeof(m), 1)
            end)
            return nothing
        elseif s == "close-me"
            ccall((:websocket_close, lib), Cvoid, (Ptr{Cvoid},), ws)
            return nothing
        elseif s == "push-after-close"
            # client closes right away; the send 300 ms later must be dropped safely
            uuid = ccall((:websocket_uuid, lib), Int, (Ptr{Cvoid},), ws)
            errormonitor(Threads.@spawn begin
                sleep(0.3)
                ccall((:shim_ws_send_uuid, lib), Cvoid, (Int, Ptr{UInt8}, Csize_t, Cint), $uuid, "late", 4, 1)
            end)
            return nothing
        end
    end
    ccall((:shim_ws_write, lib), Cint, (Ptr{Cvoid}, Ptr{UInt8}, Csize_t, Cint), ws, data, len, is_text)
    nothing
end

function sse_open(sse::Ptr{Cvoid})
    dup = ccall((:http_sse_dup, lib), Ptr{Cvoid}, (Ptr{Cvoid},), sse)
    errormonitor(Threads.@spawn begin
        for i in 1:5
            m = "event $i from thread $(Threads.threadid())"
            ccall((:shim_sse_write, lib), Cint, (Ptr{Cvoid}, Ptr{UInt8}, Csize_t), $dup, m, sizeof(m))
            sleep(0.1)
        end
        ccall((:http_sse_close, lib), Cint, (Ptr{Cvoid},), $dup)
        ccall((:http_sse_free, lib), Cvoid, (Ptr{Cvoid},), $dup)
    end)
    nothing
end
sse_close(sse::Ptr{Cvoid}) = (Threads.atomic_add!(sse_closes, 1); nothing)

function on_upgrade(h::Ptr{Cvoid}, proto::Ptr{UInt8}, len::Csize_t)
    p = unsafe_string(proto, len)
    if p == "websocket"
        ccall((:shim_upgrade2ws, lib), Cint, (Ptr{Cvoid}, Ptr{Cvoid}), h, C_NULL)
    elseif p == "sse"
        ccall((:shim_upgrade2sse, lib), Cint, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}), h, sse_open_c[], sse_close_c[], C_NULL)
    else
        ccall((:http_send_error, lib), Cint, (Ptr{Cvoid}, Csize_t), h, 400)
    end
    nothing
end

function timer_cb(::Ptr{Cvoid})
    n = Threads.atomic_add!(timer_calls, 1)
    n == 0 && (timer_t0[] = time())
    timer_tlast[] = time()
    nothing
end
timer_fin(::Ptr{Cvoid}) = (Threads.atomic_add!(timer_done, 1); nothing)

function on_request(h::Ptr{Cvoid})
    path = getstr(:shim_path, h); method = getstr(:shim_method, h)
    if path == "/hello"
        send(h, "Hello World!\n")
    elseif path == "/info"
        send(h, "method=$method host=$(repr(header(h, "host"))) nheaders=$(ccall((:shim_header_count, lib), Csize_t, (Ptr{Cvoid},), h)) bodylen=$(ccall((:shim_body_len, lib), Int, (Ptr{Cvoid},), h))\n")
    elseif path == "/upload"
        n = ccall((:shim_body_len, lib), Int, (Ptr{Cvoid},), h)
        ctx = SHA256_CTX(); got = 0; len = Ref{Csize_t}(0)
        while n > 0
            p = ccall((:shim_body_read, lib), Ptr{UInt8}, (Ptr{Cvoid}, Int, Ref{Csize_t}), h, 1 << 20, len)
            (p == C_NULL || len[] == 0) && break
            update!(ctx, unsafe_wrap(Array, p, len[])); got += len[]
        end
        send(h, "len=$n read=$got sha256=$(bytes2hex(digest!(ctx)))\n")
    elseif path == "/sendfile"
        f = joinpath(HERE, "public", "a.txt")
        fd = ccall(:open, Cint, (Cstring, Cint), f, 0)
        ccall((:http_sendfile, lib), Cint, (Ptr{Cvoid}, Cint, UInt, UInt), h, fd, filesize(f), 0)
    elseif path == "/stream"
        keep = getstr(:shim_query, h) == "keep"
        uuid = ccall((:http_hijack, lib), Int, (Ptr{Cvoid}, Ptr{Cvoid}), h, C_NULL)
        errormonitor(Threads.@spawn begin
            rawwrite($uuid, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n")
            for i in 1:10
                c = "chunk $i\n"
                rawwrite($uuid, string(sizeof(c), base = 16) * "\r\n" * c * "\r\n")
                sleep(0.05)
            end
            rawwrite($uuid, "0\r\n\r\n")
            $keep || ccall((:fio_close, lib), Cvoid, (Int,), $uuid)
        end)
    elseif path == "/publish"
        m = getstr(:shim_query, h)
        errormonitor(Threads.@spawn begin
            mm = "$($m) via thread $(Threads.threadid())"
            ccall((:shim_publish, lib), Cvoid, (Cstring, Csize_t, Ptr{UInt8}, Csize_t), "room", 4, mm, sizeof(mm))
        end)
        send(h, "ok\n")
    elseif path == "/timer"
        q = getstr(:shim_query, h); reps = isempty(q) ? 20 : parse(Int, q)
        timer_calls[] = 0; timer_done[] = 0
        r = ccall((:fio_run_every, lib), Cint, (Csize_t, Csize_t, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}), 100, reps, timer_cb_c[], C_NULL, timer_fin_c[])
        send(h, "fio_run_every=$r reps=$reps\n")
    elseif path == "/stats"
        send(h, "opens=$(opens[]) closes=$(closes[]) sse_closes=$(sse_closes[]) open_conns=$(length(conns)) cb_threads=$(collect(cb_tids)) req_thread=$(Threads.threadid()) timer_calls=$(timer_calls[]) timer_done=$(timer_done[]) timer_span=$(round(timer_tlast[] - timer_t0[], digits=3)) sent_ok=$(ccall((:shim_sent_ok, lib), Clong, ())) sent_dropped=$(ccall((:shim_sent_dropped, lib), Clong, ()))\n")
    else
        ccall((:http_send_error, lib), Cint, (Ptr{Cvoid}, Csize_t), h, 404)
    end
    nothing
end

const sse_open_c = Ref{Ptr{Cvoid}}(); const sse_close_c = Ref{Ptr{Cvoid}}()
const timer_cb_c = Ref{Ptr{Cvoid}}(); const timer_fin_c = Ref{Ptr{Cvoid}}()

function main()
    sse_open_c[] = @cfunction(sse_open, Cvoid, (Ptr{Cvoid},))
    sse_close_c[] = @cfunction(sse_close, Cvoid, (Ptr{Cvoid},))
    timer_cb_c[] = @cfunction(timer_cb, Cvoid, (Ptr{Cvoid},))
    timer_fin_c[] = @cfunction(timer_fin, Cvoid, (Ptr{Cvoid},))
    ccall((:shim_ws_cbs, lib), Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}),
          @cfunction(ws_msg, Cvoid, (Ptr{Cvoid}, Ptr{UInt8}, Csize_t, Cint)),
          @cfunction(ws_open, Cvoid, (Ptr{Cvoid},)),
          @cfunction(ws_close, Cvoid, (Int, Ptr{Cvoid})))
    ccall((:shim_sizes, lib), Cvoid, ())
    pub = joinpath(HERE, "public")
    s = HttpSettings(@cfunction(on_request, Cvoid, (Ptr{Cvoid},)),
                     @cfunction(on_upgrade, Cvoid, (Ptr{Cvoid}, Ptr{UInt8}, Csize_t)),
                     C_NULL, C_NULL, C_NULL, pointer(pub), 0, 0, MAXBODY << 20, 0, C_NULL, 0, 0, 0, 0, 0, 0, 0, 0)
    r = GC.@preserve pub ccall((:http_listen, lib), Int, (Cstring, Ptr{Cchar}, HttpSettings), PORT, C_NULL, s)
    r < 0 && error("http_listen failed")
    println(stderr, "listening on $PORT pid=$(getpid()) threads=$(Threads.nthreads())")
    # REACTOR=main reproduces the stall: with thread 1 parked in C nobody runs
    # Julia's libuv loop, so sleep/Timer/IO in other tasks never wake.
    if get(ENV, "REACTOR", "spawn") == "main"
        @ccall gc_safe=true lib.fio_start(FioStartArgs(1, 1)::FioStartArgs)::Cvoid
    else
        wait(Threads.@spawn @ccall gc_safe=true lib.fio_start(FioStartArgs(1, 1)::FioStartArgs)::Cvoid)
    end
end
main()
