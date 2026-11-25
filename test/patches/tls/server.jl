# usage: julia -t 3 server.jl <lib> <port> <cert> <key>
# Env: RESP=A (copying send, default) | C (no-copy, two packets) | D (no-copy, gathered)
#      FIO_THREADS=1 (reactor threads)   GCLOOP=1 (a task calls GC.gc() continuously)
#      TLS_MIN=1.3  TLS_CIPHERS=...  TLS_SUITES=...  TLS_SERVER_PREF=1  (need the patched library)
using SHA
const lib = ARGS[1]
const PORT = ARGS[2]
const MODE = Dict("A" => 0, "C" => 3, "D" => 4)[get(ENV, "RESP", "A")]

struct HttpSettings
    on_request::Ptr{Cvoid}; on_upgrade::Ptr{Cvoid}; on_response::Ptr{Cvoid}; on_finish::Ptr{Cvoid}
    udata::Ptr{Cvoid}; public_folder::Ptr{Cchar}; public_folder_length::Csize_t
    max_header_size::Csize_t; max_body_size::Csize_t; max_clients::Int; tls::Ptr{Cvoid}
    reserved1::Int; reserved2::Int; reserved3::Int; ws_max_msg_size::Csize_t
    timeout::UInt8; ws_timeout::UInt8; log::UInt8; is_client::UInt8
end
struct FioStartArgs; threads::Int16; workers::Int16; end
struct Slice; ptr::Ptr{UInt8}; len::Csize_t; end

const SMALL_JSON = """{"id":1,"name":"alice","email":"alice@example.com","tags":["admin","reviewer"],"created_at":"2024-01-01T12:00:00Z","status":"active","login_count":42}"""
pattern(n::Int) = UInt8[((i * 7 + (i >>> 10)) & 0xff) % UInt8 for i in 0:n-1]
const STATIC = Dict{Int,Vector{UInt8}}()
const STATIC_LOCK = ReentrantLock()

# Bodies handed to the socket without a copy stay rooted until facil.io releases them.
const ROOTS = Dict{Ptr{Cvoid},Tuple{Vector{UInt8},Int}}()
const ROOT_LOCK = Threads.SpinLock()
function root!(b::Vector{UInt8})
    p = Ptr{Cvoid}(pointer(b))
    lock(ROOT_LOCK)
    _, c = get(ROOTS, p, (b, 0))
    ROOTS[p] = (b, c + 1)
    unlock(ROOT_LOCK)
    return p
end
function on_dealloc(p::Ptr{Cvoid})::Cvoid
    lock(ROOT_LOCK)
    e = get(ROOTS, p, nothing)
    if e !== nothing
        e[2] == 1 ? delete!(ROOTS, p) : (ROOTS[p] = (e[1], e[2] - 1))
    end
    unlock(ROOT_LOCK)
    return nothing
end
const DEALLOC = Ref{Ptr{Cvoid}}()

respond(h, ctype::String, body, mode = 0) =
    ccall((:shim_respond, lib), Cint, (Ptr{Cvoid}, Cint, Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t, Ptr{Cvoid}),
          h, mode, ctype, sizeof(ctype), body, sizeof(body), DEALLOC[])

function path_of(h)
    p = Ref(Slice(C_NULL, 0)); q = Ref(Slice(C_NULL, 0))
    ccall((:shim_path, lib), Cvoid, (Ptr{Cvoid}, Ref{Slice}, Ref{Slice}), h, p, q)
    return unsafe_string(p[].ptr, p[].len)
end

function on_request(h::Ptr{Cvoid})::Cvoid
    t = path_of(h)
    if t == "/json"
        respond(h, "application/json", SMALL_JSON)
    elseif startswith(t, "/s/")
        n = parse(Int, SubString(t, 4))
        b = lock(() -> get!(() -> pattern(n), STATIC, n), STATIC_LOCK)
        MODE != 0 && root!(b)
        respond(h, "application/octet-stream", b, MODE)
    elseif startswith(t, "/fresh/")
        # a new array per request: only the root table keeps it alive under RESP=C
        n = parse(Int, SubString(t, 8))
        b = pattern(n)
        MODE != 0 && root!(b)
        respond(h, "application/octet-stream", b, MODE)
    elseif t == "/upload"
        n = ccall((:shim_body_len, lib), Int, (Ptr{Cvoid},), h)
        ctx = SHA256_CTX(); got = 0; len = Ref{Csize_t}(0)
        while n > 0
            p = ccall((:shim_body_read, lib), Ptr{UInt8}, (Ptr{Cvoid}, Int, Ref{Csize_t}), h, 1 << 20, len)
            (p == C_NULL || len[] == 0) && break
            update!(ctx, unsafe_wrap(Array, p, len[])); got += len[]
        end
        respond(h, "text/plain", "len=$n read=$got sha256=$(bytes2hex(digest!(ctx)))\n")
    elseif t == "/stats"
        respond(h, "application/json", """{"roots":$(length(ROOTS)),"rss_kb":$(Sys.maxrss() ÷ 1024),"capa":$(ccall((:shim_capa, lib), Csize_t, ()))}""")
    else
        ccall((:http_send_error, lib), Cint, (Ptr{Cvoid}, Csize_t), h, 404)
    end
    return nothing
end

function main()
    DEALLOC[] = @cfunction(on_dealloc, Cvoid, (Ptr{Cvoid},))
    tls = ccall((:fio_tls_new, lib), Ptr{Cvoid}, (Cstring, Cstring, Cstring, Ptr{Cchar}), "localhost", ARGS[3], ARGS[4], C_NULL)
    if any(k -> haskey(ENV, k), ("TLS_MIN", "TLS_CIPHERS", "TLS_SUITES", "TLS_SERVER_PREF"))
        vers = Dict("1.2" => 0x0303, "1.3" => 0x0304)
        r = ccall((:fio_tls_configure, lib), Cint, (Ptr{Cvoid}, Cint, Cint, Cstring, Cstring, Cint), tls,
                  get(vers, get(ENV, "TLS_MIN", ""), 0), 0,
                  haskey(ENV, "TLS_CIPHERS") ? ENV["TLS_CIPHERS"] : C_NULL,
                  haskey(ENV, "TLS_SUITES") ? ENV["TLS_SUITES"] : C_NULL,
                  get(ENV, "TLS_SERVER_PREF", "0") == "1")
        r == 0 || error("fio_tls_configure failed")
    end
    s = HttpSettings(@cfunction(on_request, Cvoid, (Ptr{Cvoid},)),
                     C_NULL, C_NULL, C_NULL, C_NULL, C_NULL, 0, 0, 100 * 1024 * 1024, 0, tls, 0, 0, 0, 0, 0, 0, 0, 0)
    r = ccall((:http_listen, lib), Int, (Cstring, Cstring, HttpSettings), PORT, "127.0.0.1", s)
    r < 0 && error("http_listen failed")
    if get(ENV, "GCLOOP", "0") == "1"
        errormonitor(Threads.@spawn while true; GC.gc(); sleep(0.001); end)
    end
    nthr = parse(Int16, get(ENV, "FIO_THREADS", "1"))
    wait(Threads.@spawn @ccall gc_safe=true lib.fio_start(FioStartArgs(nthr, 1)::FioStartArgs)::Cvoid)
end
main()
