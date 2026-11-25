# usage: julia -t 3 server.jl <lib> <port>
# Env: FIO_THREADS (reactor threads, default 1), WS_MAX_MSG (bytes), WS_TIMEOUT (s)
const lib = ARGS[1]
const PORT = ARGS[2]

struct HttpSettings
    on_request::Ptr{Cvoid}; on_upgrade::Ptr{Cvoid}; on_response::Ptr{Cvoid}; on_finish::Ptr{Cvoid}
    udata::Ptr{Cvoid}; public_folder::Ptr{Cchar}; public_folder_length::Csize_t
    max_header_size::Csize_t; max_body_size::Csize_t; max_clients::Int; tls::Ptr{Cvoid}
    reserved1::Int; reserved2::Int; reserved3::Int; ws_max_msg_size::Csize_t
    timeout::UInt8; ws_timeout::UInt8; log::UInt8; is_client::UInt8
end
struct FioStartArgs; threads::Int16; workers::Int16; end
struct Slice; ptr::Ptr{UInt8}; len::Csize_t; end

const opens = Threads.Atomic{Int}(0)
const closes = Threads.Atomic{Int}(0)
const published = Threads.Atomic{Int}(0)

respond(h, ctype::String, body) =
    ccall((:shim_respond, lib), Cint, (Ptr{Cvoid}, Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t),
          h, ctype, sizeof(ctype), body, sizeof(body))

# Writes `v` as `width` zero-padded decimal digits ending at index `last`.
function digits!(buf::Vector{UInt8}, last::Int, width::Int, v::Integer)
    for i in 0:width-1
        @inbounds buf[last - i] = UInt8('0') + (v % 10) % UInt8
        v = v ÷ 10
    end
end
# Message layout: 10-digit sequence, space, 20-digit scheduled send time (ns), space, padding.
# The loop allocates nothing, so the garbage collector does not blur the memory measurements.
function publisher(n::Int, rate::Int, size::Int)
    m = fill(UInt8('x'), size)
    m[11] = m[32] = UInt8(' ')
    t0 = time_ns()
    sent = 0
    while sent < n
        due = min(n, (time_ns() - t0) * rate ÷ 1_000_000_000 + 1)
        while sent < due
            digits!(m, 10, 10, sent)
            digits!(m, 31, 20, t0 + sent * 1_000_000_000 ÷ rate)
            ccall((:shim_publish, lib), Cvoid, (Cstring, Csize_t, Ptr{UInt8}, Csize_t), "room", 4, m, size)
            sent += 1
        end
        published[] = sent
        Libc.systemsleep(0.001)
    end
end

function path_of(h)
    p = Ref(Slice(C_NULL, 0)); q = Ref(Slice(C_NULL, 0))
    ccall((:shim_path, lib), Cvoid, (Ptr{Cvoid}, Ref{Slice}, Ref{Slice}), h, p, q)
    return unsafe_string(p[].ptr, p[].len), (q[].ptr == C_NULL ? "" : unsafe_string(q[].ptr, q[].len))
end

function on_request(h::Ptr{Cvoid})::Cvoid
    t, q = path_of(h)
    if t == "/start"
        a = Dict(split(kv, '=') for kv in split(q, '&'))
        n = parse(Int, a["n"]); rate = parse(Int, a["rate"]); sz = parse(Int, a["size"])
        published[] = 0
        errormonitor(Threads.@spawn publisher($n, $rate, $sz))
        respond(h, "text/plain", "started\n")
    elseif t == "/stats"
        respond(h, "application/json", """{"opens":$(opens[]),"closes":$(closes[]),"published":$(published[]),"extra":$(unsafe_string(ccall((:shim_stats, lib), Cstring, ())))}""")
    else
        ccall((:http_send_error, lib), Cint, (Ptr{Cvoid}, Csize_t), h, 404)
    end
    return nothing
end

function on_upgrade(h::Ptr{Cvoid}, proto::Ptr{UInt8}, len::Csize_t)::Cvoid
    t, _ = path_of(h)
    ccall((:shim_upgrade2ws, lib), Cint, (Ptr{Cvoid}, Ptr{Cvoid}), h, Ptr{Cvoid}(t == "/sub" ? 1 : 0))
    return nothing
end
function ws_open(ws::Ptr{Cvoid})::Cvoid
    Threads.atomic_add!(opens, 1)
    if ccall((:websocket_udata_get, lib), Ptr{Cvoid}, (Ptr{Cvoid},), ws) != C_NULL
        ccall((:shim_ws_subscribe, lib), UInt, (Ptr{Cvoid}, Cstring, Csize_t), ws, "room", 4)
    end
    return nothing
end
ws_close(uuid::Int, udata::Ptr{Cvoid})::Cvoid = (Threads.atomic_add!(closes, 1); nothing)
function ws_msg(ws::Ptr{Cvoid}, data::Ptr{UInt8}, len::Csize_t, is_text::Cint)::Cvoid
    if len >= 8 && len <= 13 && unsafe_string(data, 8) == "close-me"
        code = len > 9 ? parse(Cint, unsafe_string(data + 9, len - 9)) : Cint(1000)
        ccall((:shim_ws_close, lib), Cvoid, (Ptr{Cvoid}, Cint), ws, code)
        return nothing
    end
    ccall((:shim_ws_write, lib), Cint, (Ptr{Cvoid}, Ptr{UInt8}, Csize_t, Cint), ws, data, len, is_text)
    return nothing
end

function main()
    ccall((:shim_ws_cbs, lib), Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}),
          @cfunction(ws_msg, Cvoid, (Ptr{Cvoid}, Ptr{UInt8}, Csize_t, Cint)),
          @cfunction(ws_open, Cvoid, (Ptr{Cvoid},)),
          @cfunction(ws_close, Cvoid, (Int, Ptr{Cvoid})))
    ccall((:shim_wake_init, lib), Cint, ())
    ccall((:shim_configure, lib), Cvoid, ())
    s = HttpSettings(@cfunction(on_request, Cvoid, (Ptr{Cvoid},)),
                     @cfunction(on_upgrade, Cvoid, (Ptr{Cvoid}, Ptr{UInt8}, Csize_t)),
                     C_NULL, C_NULL, C_NULL, C_NULL, 0, 0, 0, 0, C_NULL, 0, 0, 0,
                     parse(Int, get(ENV, "WS_MAX_MSG", "0")), 0, parse(UInt8, get(ENV, "WS_TIMEOUT", "0")), 0, 0)
    r = ccall((:http_listen, lib), Int, (Cstring, Cstring, HttpSettings), PORT, "127.0.0.1", s)
    r < 0 && error("http_listen failed")
    println("READY"); flush(stdout)
    nt = parse(Int16, get(ENV, "FIO_THREADS", "1"))
    wait(Threads.@spawn @ccall gc_safe=true lib.fio_start(FioStartArgs(nt, 1)::FioStartArgs)::Cvoid)
end
main()
