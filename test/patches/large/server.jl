# Usage: julia -t 2 server.jl <A|B|B0|C|D> <port>
#   A  http_send_body (copies)          B  stock calls, head then fio_write2 (copy when closing)
#   B0 as B without the closing fallback C  patched, two packets      D  patched, one writev
# Env: THRESH=<bytes> bodies below it use the copying path; GCLOOP=1 runs GC.gc() in a loop.
const VARIANT = ARGS[1]
const MODE = Dict("A" => 0, "B" => 1, "B0" => 2, "C" => 3, "D" => 4)[VARIANT]
const LIB = ENV["FIO_LIB"]
const THRESH = parse(Int, get(ENV, "THRESH", "0"))
const NOROOT = get(ENV, "NOROOT", "0") == "1"  # negative control: do not keep bodies alive

struct HttpSettings
    on_request::Ptr{Cvoid}; on_upgrade::Ptr{Cvoid}; on_response::Ptr{Cvoid}; on_finish::Ptr{Cvoid}
    udata::Ptr{Cvoid}; public_folder::Ptr{Cchar}; public_folder_length::Csize_t
    max_header_size::Csize_t; max_body_size::Csize_t; max_clients::Int; tls::Ptr{Cvoid}
    reserved1::Int; reserved2::Int; reserved3::Int; ws_max_msg_size::Csize_t
    timeout::UInt8; ws_timeout::UInt8; log::UInt8; is_client::UInt8
end
struct FioStartArgs; threads::Int16; workers::Int16; end
struct Slice; ptr::Ptr{UInt8}; len::Csize_t; end
struct CReq
    method_code::Int32; nheaders::Int32
    method::Slice; path::Slice; query::Slice; version::Slice; body::Slice
end
const Headers = Vector{Pair{String,String}}
const Body = Union{String,Vector{UInt8}}
struct Response; status::Int; headers::Headers; body::Body; end

const REQ = Ref{CReq}()
const OUT_NAMES = Vector{Slice}(undef, 32)
const OUT_VALUES = Vector{Slice}(undef, 32)

# Bodies handed to the socket, keyed by address, with a count because one
# object can be in flight on many connections at once.
const ROOTS = Dict{Ptr{Cvoid},Tuple{Body,Int}}()
const ROOT_LOCK = Threads.SpinLock()
const N_ROOTED = Threads.Atomic{Int}(0)
const N_RELEASED = Threads.Atomic{Int}(0)
const N_RELEASE_MISS = Threads.Atomic{Int}(0)

function root!(b::Body)
    p = Ptr{Cvoid}(pointer(b))
    lock(ROOT_LOCK)
    _, c = get(ROOTS, p, (b, 0))
    ROOTS[p] = (b, c + 1)
    unlock(ROOT_LOCK)
    Threads.atomic_add!(N_ROOTED, 1)
    return p
end

function on_dealloc(p::Ptr{Cvoid})::Cvoid
    lock(ROOT_LOCK)
    e = get(ROOTS, p, nothing)
    if e === nothing
        Threads.atomic_add!(N_RELEASE_MISS, 1)
    elseif e[2] == 1
        delete!(ROOTS, p)
    else
        ROOTS[p] = (e[1], e[2] - 1)
    end
    unlock(ROOT_LOCK)
    Threads.atomic_add!(N_RELEASED, 1)
    return nothing
end
const DEALLOC = Ref{Ptr{Cvoid}}()

function respond(h::Ptr{Cvoid}, res::Response)
    hs = res.headers
    n = length(hs)
    b = res.body
    mode = sizeof(b) < THRESH ? 0 : MODE
    GC.@preserve res b begin
        @inbounds for i in 1:n
            k, v = hs[i]
            OUT_NAMES[i] = Slice(pointer(k), sizeof(k))
            OUT_VALUES[i] = Slice(pointer(v), sizeof(v))
        end
        mode != 0 && !NOROOT && root!(b)
        ccall((:jlshim_respond2, LIB), Cint,
              (Ptr{Cvoid}, Cint, Cint, Ptr{Slice}, Ptr{Slice}, Cint, Ptr{UInt8}, Csize_t, Ptr{Cvoid}),
              h, mode, res.status, OUT_NAMES, OUT_VALUES, n, b, sizeof(b), DEALLOC[])
    end
    return nothing
end

pattern(n::Int) = UInt8[((i * 7 + (i >>> 10)) & 0xff) % UInt8 for i in 0:n-1]
const STATIC = Dict{Int,Vector{UInt8}}()
const XBODY = Dict{Int,Vector{UInt8}}()
const OCTET = ["content-type" => "application/octet-stream"]
const JSONH = ["content-type" => "application/json"]
const NOH = Headers()
const SEQ = Ref(0)
const GCS = Threads.Atomic{Int}(0)

function fresh(n::Int)
    seq = (SEQ[] += 1)
    v = Vector{UInt8}(undef, n)
    fill!(v, seq % UInt8)
    for k in 0:min(7, n - 1)
        v[k+1] = ((seq >>> (8k)) & 0xff) % UInt8
    end
    return v
end

function handler(t::String)::Response
    if startswith(t, "/s/")
        n = parse(Int, SubString(t, 4))
        b = get!(() -> pattern(n), STATIC, n)
        return Response(200, OCTET, b)
    elseif startswith(t, "/x/")
        n = parse(Int, SubString(t, 4))
        return Response(200, OCTET, get!(() -> fill(UInt8('x'), n), XBODY, n))
    elseif startswith(t, "/fresh/")
        return Response(200, OCTET, fresh(parse(Int, SubString(t, 8))))
    elseif startswith(t, "/freshstr/")
        n = parse(Int, SubString(t, 11))
        seq = (SEQ[] += 1)
        return Response(200, OCTET, repeat(string(Char(UInt8('a') + seq % 26)), n))
    elseif t == "/stats"
        lock(ROOT_LOCK); live = length(ROOTS); unlock(ROOT_LOCK)
        return Response(200, JSONH, """{"variant":"$VARIANT","live":$live,"rooted":$(N_ROOTED[]),"released":$(N_RELEASED[]),"miss":$(N_RELEASE_MISS[]),"gcs":$(GCS[]),"seq":$(SEQ[])}""")
    else
        return Response(404, NOH, "")
    end
end

function on_request(h::Ptr{Cvoid})::Cvoid
    ccall((:jlshim_req_head, LIB), Cint, (Ptr{Cvoid}, Ref{CReq}), h, REQ)
    r = REQ[]
    respond(h, handler(unsafe_string(r.path.ptr, r.path.len)))
    return nothing
end

function main()
    DEALLOC[] = @cfunction(on_dealloc, Cvoid, (Ptr{Cvoid},))
    cb = @cfunction(on_request, Cvoid, (Ptr{Cvoid},))
    settings = HttpSettings(cb, C_NULL, C_NULL, C_NULL, C_NULL, C_NULL,
                            0, 0, 0, 0, C_NULL, 0, 0, 0, 0, 0, 0, 0, 0)
    r = ccall((:http_listen, LIB), Int, (Cstring, Cstring, HttpSettings), ARGS[2], "127.0.0.1", settings)
    r < 0 && error("http_listen failed")
    if get(ENV, "GCLOOP", "0") == "1"
        Threads.@spawn while true
            junk = [fill(0xee, rand(1:300_000)) for _ in 1:16]
            GC.gc()
            Threads.atomic_add!(GCS, 1)
            junk = nothing
            yield()
        end
    end
    args = FioStartArgs(1, 1)
    if get(ENV, "MAINTHREAD", "0") == "1"
        @ccall LIB.fio_start(args::FioStartArgs)::Cvoid
    else
        t = Threads.@spawn @ccall gc_safe=true LIB.fio_start(args::FioStartArgs)::Cvoid
        wait(t)
    end
end
main()
