# Raw HTTP/1.x client for the static, streaming, SSE and compression tests:
# exact control over framing, pipelining and connection reuse.
module M6Http

using Sockets

export rawconn, send_raw, read_response, request, get1, Resp, wait_until

struct Resp
    status::Int
    headers::Dict{String,String}
    body::Vector{UInt8}
    chunks::Int
end
Base.getindex(r::Resp, k::AbstractString) = r.headers[lowercase(k)]
Base.haskey(r::Resp, k::AbstractString) = haskey(r.headers, lowercase(k))
text(r::Resp) = String(copy(r.body))

function rawconn(port; timeout = 20)
    s = connect(ip"127.0.0.1", port)
    t = Timer(_ -> close(s), timeout)
    s, t
end

function wait_until(f; timeout = 10)
    t0 = time()
    while !f()
        time() - t0 > timeout && return false
        sleep(0.01)
    end
    true
end

send_raw(s, data) = (write(s, data); flush(s))

function read_head(s)
    head = String(readuntil(s, "\r\n\r\n"))
    isempty(head) && throw(EOFError())
    lines = split(head, "\r\n")
    status = parse(Int, split(lines[1], ' ')[2])
    hs = Dict{String,String}()
    for l in lines[2:end]
        i = findfirst(':', l)
        i === nothing && continue
        k = lowercase(strip(l[1:i-1]))
        v = strip(l[i+1:end])
        hs[k] = haskey(hs, k) ? hs[k] * ", " * v : v
    end
    status, hs
end

"""
Reads one response. `head` = the request was HEAD. A body with neither length
nor chunked framing is read to EOF.
"""
function read_response(s; head = false)
    status, hs = read_head(s)
    body = UInt8[]
    chunks = 0
    if head || status == 304 || status == 204 || 100 <= status < 200
    elseif get(hs, "transfer-encoding", "") == "chunked"
        while true
            line = readline(s)
            n = parse(Int, split(line, ';')[1]; base = 16)
            if n == 0
                readline(s)
                break
            end
            append!(body, read(s, n))
            chunks += 1
            readline(s)
        end
    elseif haskey(hs, "content-length")
        body = read(s, parse(Int, hs["content-length"]))
    else
        body = read(s)
    end
    Resp(status, hs, body, chunks)
end

function request(method, path; headers = Pair{String,String}[], body = "", version = "1.1")
    io = IOBuffer()
    print(io, method, " ", path, " HTTP/", version, "\r\nHost: 127.0.0.1\r\n")
    for (k, v) in headers
        print(io, k, ": ", v, "\r\n")
    end
    isempty(body) || print(io, "Content-Length: ", sizeof(body), "\r\n")
    print(io, "\r\n", body)
    String(take!(io))
end

"One request on a fresh connection."
function get1(port, path; method = "GET", headers = Pair{String,String}[], body = "", version = "1.1")
    s, t = rawconn(port)
    try
        send_raw(s, request(method, path; headers, body, version))
        read_response(s; head = method == "HEAD")
    finally
        close(t)
        close(s)
    end
end

end
