struct CSlice
    ptr::Ptr{UInt8}
    len::Int64
end

struct CHeader
    code::Int32
    pad::Int32
    name::CSlice
    value::CSlice
end

struct CRequest
    method::CSlice
    path::CSlice
    query::CSlice
    body::CSlice
    version::Int32
    nheaders::Int32
    headers::Ptr{CHeader}
end

const VERSIONS = (Versions.HTTP_09, Versions.HTTP_10, Versions.HTTP_11, Versions.HTTP_2, Versions.HTTP_3)

function init_http_tables()
    names = [s for (_, s) in HttpTypes.STANDARD_HEADER_TABLE]
    lens = UInt8[sizeof(s) for s in names]
    ptrs = [pointer(s) for s in names]
    GC.@preserve names begin
        @ccall LIBFJL.fjl_http_init(ptrs::Ptr{Ptr{UInt8}}, lens::Ptr{UInt8}, length(names)::Cint)::Cint
    end
    nothing
end

"""
    read_request(h) -> Request{String}

Copies the request facil.io parsed on `h` into HttpTypes values, with the body
facil.io buffered. Throws an HttpTypes error when the method, target or a
header name is invalid. Internal: the server calls `read_request(srv, h)`,
which applies `before_body` and falls back to this method for requests
without a body.
"""
@noinline function read_request(h::Ptr{Cvoid})
    r = unsafe_load(@ccall LIBFJL.fjl_req_read(h::Ptr{Cvoid})::Ptr{CRequest})
    m = HttpMethod(r.method.ptr, r.method.len)
    u = HttpTypes.uri_from_target(r.path.ptr, r.path.len, r.query.ptr, r.query.len)
    v = 1 <= r.version <= 5 ? @inbounds(VERSIONS[r.version]) : Versions.HTTP_11
    n = Int(r.nheaders)
    hm = HeaderMap{HeaderValue}(n)
    for i in 1:n
        c = unsafe_load(r.headers, i)
        name = c.code != 0 ? HttpTypes.standard_header(c.code) : HeaderName(c.name.ptr, c.name.len)
        append!(hm, name, HttpTypes.unchecked(HeaderValue, c.value.ptr, c.value.len))
    end
    body = r.body.len > 0 ? unsafe_string(r.body.ptr, r.body.len) : ""
    Request(m, u, v, hm, Extensions(), body)
end
