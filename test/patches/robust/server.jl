# usage: julia -t 2 server.jl <lib> <port>   (env THREADS: reactor threads, default 1)
# env: PUBLIC (static folder), MAXBODY (MiB, default 64), TIMEOUT (s), HDR_TIMEOUT (s, patched lib only)
using SHA, Libdl
const lib = ARGS[1]
const PORT = ARGS[2]
const MAXBODY = parse(Int, get(ENV, "MAXBODY", "64"))
const HERE = @__DIR__

struct HttpSettings
    on_request::Ptr{Cvoid}; on_upgrade::Ptr{Cvoid}; on_response::Ptr{Cvoid}; on_finish::Ptr{Cvoid}
    udata::Ptr{Cvoid}; public_folder::Ptr{Cchar}; public_folder_length::Csize_t
    max_header_size::Csize_t; max_body_size::Csize_t; max_clients::Int; tls::Ptr{Cvoid}
    reserved1::Int; reserved2::Int; reserved3::Int; ws_max_msg_size::Csize_t
    timeout::UInt8; ws_timeout::UInt8; log::UInt8; is_client::UInt8
end
struct FioStartArgs; threads::Int16; workers::Int16; end

function getstr(f::Symbol, h)
    len = Ref{Csize_t}(0)
    p = ccall(dlsym(HANDLE, f), Ptr{UInt8}, (Ptr{Cvoid}, Ref{Csize_t}), h, len)
    p == C_NULL ? "" : unsafe_string(p, len[])
end
function header(h, name)
    len = Ref{Csize_t}(0)
    p = ccall((:shim_header, lib), Ptr{UInt8}, (Ptr{Cvoid}, Cstring, Csize_t, Ref{Csize_t}), h, name, sizeof(name), len)
    p == C_NULL ? nothing : unsafe_string(p, len[])
end
send(h, s) = ccall((:http_send_body, lib), Cint, (Ptr{Cvoid}, Ptr{UInt8}, Csize_t), h, s, sizeof(s))
sethdr(h, n, v) = ccall((:shim_set_header, lib), Cint, (Ptr{Cvoid}, Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t), h, n, sizeof(n), v, sizeof(v))

const HANDLE = dlopen(lib)
const SMALL_JSON = """{"id":1,"name":"alice","email":"alice@example.com","tags":["admin","reviewer"],"created_at":"2024-01-01T12:00:00Z","status":"active","login_count":42}"""
const BIG = repeat("x", 1 << 20)

function on_request(h::Ptr{Cvoid})::Cvoid
    path = getstr(:shim_path, h)
    if path == "/json"
        sethdr(h, "content-type", "application/json")
        send(h, SMALL_JSON)
    elseif path == "/big"
        send(h, BIG)
    elseif path == "/hello"
        send(h, "Hello World!\n")
    elseif path == "/info"
        send(h, "method=$(getstr(:shim_method, h)) nheaders=$(ccall((:shim_header_count, lib), Csize_t, (Ptr{Cvoid},), h)) bodylen=$(ccall((:shim_body_len, lib), Int, (Ptr{Cvoid},), h))\n")
    elseif path == "/upload"
        n = ccall((:shim_body_len, lib), Int, (Ptr{Cvoid},), h)
        ctx = SHA256_CTX(); got = 0; len = Ref{Csize_t}(0)
        while n > 0
            p = ccall((:shim_body_read, lib), Ptr{UInt8}, (Ptr{Cvoid}, Int, Ref{Csize_t}), h, 1 << 20, len)
            (p == C_NULL || len[] == 0) && break
            update!(ctx, unsafe_wrap(Array, p, len[])); got += len[]
        end
        send(h, "len=$n read=$got sha256=$(bytes2hex(digest!(ctx)))\n")
    elseif path == "/flood"
        ccall((:shim_flood, lib), Cvoid, (Ptr{Cvoid}, Cint), h, 1500)
    elseif path == "/sendfile"
        f = joinpath(PUB, "a.txt")
        fd = ccall(:open, Cint, (Cstring, Cint), f, 0)
        ccall((:http_sendfile, lib), Cint, (Ptr{Cvoid}, Cint, UInt, UInt), h, fd, filesize(f), 0)
    else
        ccall((:http_send_error, lib), Cint, (Ptr{Cvoid}, Csize_t), h, 404)
    end
    nothing
end

const PUB = get(ENV, "PUBLIC", joinpath(HERE, "public"))
function main()
    for (env, sym) in (("HDR_TIMEOUT", :http1_header_timeout_set), ("ACCEPT_BATCH", :fio_accept_batch_set))
        haskey(ENV, env) || continue
        p = dlsym(HANDLE, sym; throw_error = false)
        p === nothing ? println(stderr, "$sym not in this lib") : ccall(p, Cvoid, (Csize_t,), parse(Int, ENV[env]))
    end
    s = HttpSettings(@cfunction(on_request, Cvoid, (Ptr{Cvoid},)), C_NULL,
                     C_NULL, C_NULL, C_NULL, pointer(PUB), 0, 0, MAXBODY << 20, 0, C_NULL, 0, 0, 0, 0,
                     parse(UInt8, get(ENV, "TIMEOUT", "0")), 0, 0, 0)
    r = GC.@preserve PUB ccall((:http_listen, lib), Int, (Cstring, Cstring, HttpSettings), PORT, "127.0.0.1", s)
    r < 0 && error("http_listen failed")
    println(stderr, "listening on $PORT pid=$(getpid())")
    wait(Threads.@spawn @ccall gc_safe=true lib.fio_start(FioStartArgs(parse(Int16, get(ENV, "THREADS", "1")), 1)::FioStartArgs)::Cvoid)
end
main()
