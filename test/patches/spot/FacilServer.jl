module FacilServer

const LIB = get(ENV, "FACIL_LIB", joinpath(@__DIR__, "libfacil_shim.dylib"))

# Mirrors `struct http_settings_s` in facil.io/lib/facil/http/http.h field for field.
struct HttpSettings
    on_request::Ptr{Cvoid}
    on_upgrade::Ptr{Cvoid}
    on_response::Ptr{Cvoid}
    on_finish::Ptr{Cvoid}
    udata::Ptr{Cvoid}
    public_folder::Ptr{Cchar}
    public_folder_length::Csize_t
    max_header_size::Csize_t
    max_body_size::Csize_t
    max_clients::Int
    tls::Ptr{Cvoid}
    reserved1::Int
    reserved2::Int
    reserved3::Int
    ws_max_msg_size::Csize_t
    timeout::UInt8
    ws_timeout::UInt8
    log::UInt8
    is_client::UInt8
end

struct FioStartArgs
    threads::Int16
    workers::Int16
end

struct Slice
    ptr::Ptr{UInt8}
    len::Csize_t
end

struct CReq
    method_code::Int32
    nheaders::Int32
    method::Slice
    path::Slice
    query::Slice
    version::Slice
    body::Slice
end

struct CHdr
    name_code::Int32
    pad::Int32
    name::Slice
    value::Slice
end

struct Method
    name::String
end
Base.:(==)(a::Method, b::Method) = a === b || a.name == b.name

const Headers = Vector{Pair{String,String}}

struct Request
    method::Method
    target::String
    headers::Headers
    body::Vector{UInt8}
end

# Only method and target are Julia objects; headers and body stay in C until asked for.
struct LazyRequest
    method::Method
    target::String
    handle::Ptr{Cvoid}
end

struct Response
    status::Int
    headers::Headers
    body::Union{String,Vector{UInt8}}
end

const METHODS = Method[]
const HEADER_NAMES = String[]
const REQ = Ref{CReq}()
const HDRS = Vector{CHdr}(undef, 64)
const OUT_NAMES = Vector{Slice}(undef, 32)
const OUT_VALUES = Vector{Slice}(undef, 32)
const SLICE = Ref{Slice}()
const INTERN = Ref(true)

function init_tables()
    empty!(METHODS); empty!(HEADER_NAMES)
    for i in 1:ccall((:jlshim_method_count, LIB), Cint, ())
        push!(METHODS, Method(unsafe_string(ccall((:jlshim_method_name, LIB), Cstring, (Cint,), i))))
    end
    for i in 1:ccall((:jlshim_header_count, LIB), Cint, ())
        push!(HEADER_NAMES, unsafe_string(ccall((:jlshim_header_name, LIB), Cstring, (Cint,), i)))
    end
end

method_const(name::String) = METHODS[findfirst(m -> m.name == name, METHODS)]

@inline str(s::Slice) = unsafe_string(s.ptr, s.len)

@inline istoken(b::UInt8) =
    (UInt8('a') <= b <= UInt8('z')) || (UInt8('0') <= b <= UInt8('9')) ||
    (UInt8('A') <= b <= UInt8('Z')) || b in (0x21, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2a, 0x2b, 0x2d, 0x2e, 0x5e, 0x5f, 0x60, 0x7c, 0x7e)

function checked_name(s::Slice)
    s.len == 0 && throw(ArgumentError("empty header name"))
    for i in 1:s.len
        istoken(unsafe_load(s.ptr, i)) || throw(ArgumentError("invalid header name"))
    end
    return str(s)
end

@inline method_of(r::CReq) =
    r.method_code != 0 ? @inbounds(METHODS[r.method_code]) : Method(str(r.method))

@inline function target_of(r::CReq)
    r.query.len == 0 && return str(r.path)
    n = r.path.len + 1 + r.query.len
    out = Base._string_n(n)
    p = pointer(out)
    unsafe_copyto!(p, r.path.ptr, r.path.len)
    unsafe_store!(p + r.path.len, UInt8('?'))
    unsafe_copyto!(p + r.path.len + 1, r.query.ptr, r.query.len)
    return out
end

function read_lazy(h::Ptr{Cvoid})
    ccall((:jlshim_req_head, LIB), Cint, (Ptr{Cvoid}, Ref{CReq}), h, REQ)
    r = REQ[]
    return LazyRequest(method_of(r), target_of(r), h)
end

function read_full(h::Ptr{Cvoid})
    n = ccall((:jlshim_req_full, LIB), Cint, (Ptr{Cvoid}, Ref{CReq}, Ptr{CHdr}, Cint),
              h, REQ, HDRS, length(HDRS))
    if n > length(HDRS)
        resize!(HDRS, n)
        ccall((:jlshim_req_full, LIB), Cint, (Ptr{Cvoid}, Ref{CReq}, Ptr{CHdr}, Cint),
              h, REQ, HDRS, n)
    end
    r = REQ[]
    headers = Headers(undef, n)
    @inbounds for i in 1:n
        c = HDRS[i]
        name = (c.name_code != 0 && INTERN[]) ? HEADER_NAMES[c.name_code] : checked_name(c.name)
        headers[i] = Pair{String,String}(name, str(c.value))
    end
    body = Vector{UInt8}(undef, r.body.len)
    r.body.len > 0 && unsafe_copyto!(pointer(body), r.body.ptr, r.body.len)
    return Request(method_of(r), target_of(r), headers, body)
end

function header(req::Request, name::String, default::String = "")
    for (k, v) in req.headers
        (k === name || k == name) && return v
    end
    return default
end

function header(req::LazyRequest, name::String, default::String = "")
    found = ccall((:jlshim_req_header, LIB), Cint, (Ptr{Cvoid}, Ptr{UInt8}, Csize_t, Ref{Slice}),
                  req.handle, name, sizeof(name), SLICE)
    return found == 0 ? default : str(SLICE[])
end

body(req::Request) = req.body
function body(req::LazyRequest)
    s = ccall((:jlshim_req_body, LIB), Slice, (Ptr{Cvoid},), req.handle)
    out = Vector{UInt8}(undef, s.len)
    s.len > 0 && unsafe_copyto!(pointer(out), s.ptr, s.len)
    return out
end

function respond(h::Ptr{Cvoid}, res::Response)
    hs = res.headers
    n = length(hs)
    if n > length(OUT_NAMES)
        resize!(OUT_NAMES, n); resize!(OUT_VALUES, n)
    end
    b = res.body
    GC.@preserve res b begin
        @inbounds for i in 1:n
            k, v = hs[i]
            OUT_NAMES[i] = Slice(pointer(k), sizeof(k))
            OUT_VALUES[i] = Slice(pointer(v), sizeof(v))
        end
        ccall((:jlshim_respond, LIB), Cint,
              (Ptr{Cvoid}, Cint, Ptr{Slice}, Ptr{Slice}, Cint, Ptr{UInt8}, Csize_t),
              h, res.status, OUT_NAMES, OUT_VALUES, n, b, sizeof(b))
    end
    return nothing
end

const SMALL_JSON = """{"id":1,"name":"alice","email":"alice@example.com","tags":["admin","reviewer"],"created_at":"2024-01-01T12:00:00Z","status":"active","login_count":42}"""
const LARGE_BODY = repeat("x", 100 * 1024)
const NO_HEADERS = Headers()
const JSON_HEADERS = ["content-type" => "application/json"]
const LARGE_HEADERS = ["content-type" => "application/octet-stream"]
const POST = Ref{Method}()

function handler(req)::Response
    t = req.target
    if t == "/tiny"
        return Response(200, NO_HEADERS, "")
    elseif t == "/json"
        return Response(200, JSON_HEADERS, SMALL_JSON)
    elseif t == "/large"
        return Response(200, LARGE_HEADERS, LARGE_BODY)
    elseif t == "/echo" && req.method === POST[]
        return Response(200, ["content-type" => "application/octet-stream",
                              "x-echo" => header(req, "x-echo", "none")], body(req))
    else
        return Response(404, NO_HEADERS, "")
    end
end

const HELLO = "Hello World!\r\n"

function on_request_a(h::Ptr{Cvoid})
    ccall((:http_send_body, LIB), Cint, (Ptr{Cvoid}, Ptr{UInt8}, Csize_t), h, HELLO, sizeof(HELLO))
    return nothing
end

function on_request_b(h::Ptr{Cvoid})
    respond(h, handler(read_lazy(h)))
    return nothing
end

function on_request_c(h::Ptr{Cvoid})
    respond(h, handler(read_full(h)))
    return nothing
end

function init()
    init_tables()
    POST[] = method_const("POST")
end

function serve(variant::String, port::String)
    init()
    cb = variant == "a" ? @cfunction(on_request_a, Cvoid, (Ptr{Cvoid},)) :
         variant == "b" ? @cfunction(on_request_b, Cvoid, (Ptr{Cvoid},)) :
         variant == "c" ? @cfunction(on_request_c, Cvoid, (Ptr{Cvoid},)) :
         error("variant must be a, b or c")
    settings = HttpSettings(cb, C_NULL, C_NULL, C_NULL, C_NULL, C_NULL,
                            0, 0, 0, 0, C_NULL, 0, 0, 0, 0, 0, 0, 0, 0)
    r = ccall((:http_listen, LIB), Int, (Cstring, Cstring, HttpSettings), port, "127.0.0.1", settings)
    r < 0 && error("http_listen failed")
    ccall((:fio_start, LIB), Cvoid, (FioStartArgs,), FioStartArgs(1, 1))
end

end
