# Facil side of the scoreboard: every endpoint the rows need, in one server.
#   julia -t N --project=bench/scoreboard/facil server.jl <port> [key=value ...]
# Keys (set per row in rows.json): handler=inline|task  reactors=N  tls=rsa|ec cert=… key=…  ws_deflate=L  ws_spawn=1  routes=json
# Endpoints that need features not built yet (M4-M8: Facil.sleep, streaming, compression,
# WebSockets, pub/sub, timers, TLS, query parsing) fail with 500 until those land.
using Facil
using JSON

const PORT = parse(Int, ARGS[1])
const OPT = Dict(String(k) => String(v) for (k, v) in (split(a, '='; limit = 2) for a in ARGS[2:end]))
const DATA = joinpath(@__DIR__, "..", "data")

const SMALL_JSON = """{"id":1,"name":"alice","email":"alice@example.com","tags":["admin","reviewer"],"created_at":"2024-01-01T12:00:00Z","status":"active","login_count":42}"""
const XBUFS = Dict{Int,Vector{UInt8}}()
const XLOCK = ReentrantLock()
xbuf(n) = lock(() -> get!(() -> fill(UInt8('x'), n), XBUFS, n), XLOCK)

const FNV_BUF = UInt8[(i * 31 + 7) & 0xff for i in 1:16384]
function fnv16k(seed)
    h = 0x811c9dc5 ⊻ (seed % UInt32)
    for _ in 1:3, b in FNV_BUF
        h = (h ⊻ b) * 0x01000193
    end
    string(h; base = 16)
end
const FLOATS = [i * 0.5 for i in 1:100_000]
const HASH_INPUT = UInt8[(i * 31 + 7) % 251 for i in 1:4096]
function fnv4k()
    h = 0x811c9dc5
    for b in HASH_INPUT
        h = (h ⊻ b) * 0x01000193
    end
    h
end
gen_doc(n) = JSON.json(Dict("count" => n, "items" => [Dict("id" => i, "name" => "user$i", "email" => "user$i@example.com",
    "active" => iseven(i), "score" => i * 1.5, "tags" => ["admin", "reviewer"]) for i in 1:n]))
checksum(b) = (isempty(b) ? 0 : Int(b[end])) + sum(Int(b[i]) for i in 1:1024:length(b); init = 0)
const SINK = Ref{Any}()
garbage(n) = (g = Vector{UInt8}(undef, n); g[1] = 1; g[end] = 2; SINK[] = g)
const PAYLOADS = Dict(splitext(f)[1] => read(joinpath(DATA, f)) for f in readdir(DATA) if endswith(f, ".json"))
const COMPRESS = Dict("gz" => :gzip, "br" => :brotli, "zstd" => :zstd)
const ENCODING = Dict("gz" => "gzip", "br" => "br", "zstd" => "zstd")

function unescape_form(s::AbstractString)
    occursin(r"[%+]", s) || return String(s)
    out, b, i = UInt8[], codeunits(s), 1
    while i <= length(b)
        c = b[i]
        if c == UInt8('%') && i + 2 <= length(b)
            push!(out, parse(UInt8, String(b[i+1:i+2]); base = 16)); i += 3
        else
            push!(out, c == UInt8('+') ? UInt8(' ') : c); i += 1
        end
    end
    String(out)
end
# Facil has no query-string parser; this is the decoding a handler would write itself.
function query_params(u)
    d = Dict{String,String}()
    for kv in eachsplit(something(query(u), ""), '&'; keepempty = false)
        k, v = '=' in kv ? split(kv, '='; limit = 2) : (kv, "")
        d[unescape_form(k)] = unescape_form(v)
    end
    d
end

text(s) = Response(StatusCodes.OK, s; headers = [header.CONTENT_TYPE => "text/plain"])
json(s) = Response(StatusCodes.OK, s; headers = [header.CONTENT_TYPE => "application/json"])

const SEQ = Threads.Atomic{Int}(0)
const OCTET = hv"application/octet-stream"
const X_ECHO = hn"x-echo"

function echo(req)
    h = HeaderMap{HeaderValue}(2)
    h[header.CONTENT_TYPE] = OCTET
    h[X_ECHO] = something(get(headers(req), X_ECHO, nothing), hv"none")
    Response(StatusCodes.OK, body(req); headers = h)
end

function handle(req)
    p = path(uri(req))
    p == "/tiny" || p == "/atiny" ? Response(StatusCodes.OK) :
    p == "/json" ? json(SMALL_JSON) :
    p == "/echo" ? echo(req) :
    p == "/hdr" ? text("$(length(headers(req))) $(length(something(get(headers(req), header.COOKIE, nothing), "")))") :
    p == "/query" ? (q = query_params(uri(req)); text("$(length(q)) $(get(q, "k7", ""))")) :
    p == "/fnv16k" ? text(fnv16k(Threads.atomic_add!(SEQ, 1) + 1)) :
    p == "/floatsum" ? text(string(sum(FLOATS))) :
    p == "/hash" ? text(string(fnv4k())) :
    p == "/parse" ? text(JSON.parse(String(body(req)))["name"]) :
    p == "/gen1k" ? json(gen_doc(9)) :
    p == "/gen50k" ? json(gen_doc(440)) :
    p == "/gc" ? (garbage(100_000); json(SMALL_JSON)) :
    p == "/gc10" ? (garbage(10_000); json(SMALL_JSON)) :
    p == "/wait1" ? (Facil.sleep(0.001); json(SMALL_JSON)) :
    p == "/wait10" ? (Facil.sleep(0.010); json(SMALL_JSON)) :
    p == "/upload" ? (b = codeunits(body(req)); text("$(length(b)) $(checksum(b))")) :
    p == "/upload/stream" ? upload_stream(req) :
    startswith(p, "/bytes/") ? Response(StatusCodes.OK, xbuf(parse(Int, p[8:end])); headers = [header.CONTENT_TYPE => "application/octet-stream"]) :
    startswith(p, "/stream/") || startswith(p, "/pstream/") ? chunked(req, p) :
    startswith(p, "/z/") ? compressed(req, p) :
    Response(StatusCodes.NOT_FOUND)
end

function upload_stream(req)
    n, s, last = 0, 0, 0x00
    for chunk in Facil.body_chunks(req)
        for i in mod(-n, 1024)+1:1024:length(chunk)
            s += chunk[i]
        end
        n += length(chunk)
        isempty(chunk) || (last = chunk[end])
    end
    text("$n $(s + (n > 0 ? Int(last) : 0))")
end

function chunked(req, p)
    _, kind, n, kb = split(p, '/')
    chunk, paced = xbuf(parse(Int, kb) * 1024), kind == "pstream"
    Facil.stream(req; headers = [header.CONTENT_TYPE => "text/plain"]) do w
        for _ in 1:parse(Int, n)
            paced && Facil.sleep(0.001)
            write(w, chunk)
        end
    end
end

function compressed(req, p)
    _, _, variant, name = split(p, '/')
    m = match(r"^(gz|br|zstd)(\d+)(stream|sync)?$", variant)
    (m === nothing || !haskey(PAYLOADS, name)) && return Response(StatusCodes.NOT_FOUND)
    algo, level = m[1], parse(Int, m[2])
    hdrs = [header.CONTENT_TYPE => "application/json", header.CONTENT_ENCODING => ENCODING[algo], header.VARY => "accept-encoding"]
    m[3] == "stream" && return Facil.stream(w -> write(w, PAYLOADS[name]), req; headers = hdrs, compress = Symbol(algo), level)
    Response(StatusCodes.OK, getproperty(Facil, COMPRESS[algo])(PAYLOADS[name]; level); headers = hdrs)
end

const STATE = (opens = Threads.Atomic{Int}(0), closes = Threads.Atomic{Int}(0), published = Threads.Atomic{Int}(0))

function publisher(n, rate, size)
    pad = "x"^(size - 32)
    t0 = time_ns()
    sent = 0
    every(1) do
        due = min(n, Int(div((time_ns() - t0) * rate, 1_000_000_000)) + 1)
        while sent < due
            publish("room", lpad(sent, 10, '0') * " " * lpad(t0 + div(sent * 1_000_000_000, rate), 20, '0') * " " * pad)
            sent += 1
        end
        STATE.published[] = sent
        sent < n
    end
end

const HAS_UPGRADE = isdefined(Facil, :is_upgrade)
is_upgrade(req) = HAS_UPGRADE && Facil.is_upgrade(req)

function route(req)
    p = path(uri(req))
    if p == "/echo" && is_upgrade(req)
        deflate = haskey(OPT, "ws_deflate") ? parse(Int, OPT["ws_deflate"]) : nothing
        spawn = get(OPT, "ws_spawn", "0") == "1"
        return websocket(req; deflate, spawn, borrow = !spawn, max_message_size = 16 * 1024 * 1024,
            on_open = ws -> Threads.atomic_add!(STATE.opens, 1),
            on_message = (ws, msg) -> send(ws, msg),
            on_close = ws -> Threads.atomic_add!(STATE.closes, 1))
    elseif p == "/sub" && is_upgrade(req)
        return websocket(req; on_open = ws -> (Threads.atomic_add!(STATE.opens, 1); subscribe(ws, "room")),
            on_close = ws -> Threads.atomic_add!(STATE.closes, 1))
    elseif p == "/start"
        q = Dict(split(kv, '='; limit = 2) for kv in split(something(query(uri(req)), ""), '&'))
        publisher(parse(Int, q["n"]), parse(Int, q["rate"]), parse(Int, q["size"]))
        return text("started\n")
    elseif p == "/stats"
        return json("""{"opens":$(STATE.opens[]),"closes":$(STATE.closes[]),"published":$(STATE.published[])}""")
    end
    handle(req)
end

# routes=json serves only /json, so a first request does not compile every endpoint's code.
json_only(req) = json(SMALL_JSON)
server = serve!(get(OPT, "routes", "all") == "json" ? json_only : route, "127.0.0.1", PORT;
    tls = haskey(OPT, "tls") ? TLSConfig(OPT["cert"], OPT["key"]) : nothing,
    inline = get(OPT, "handler", "inline") == "inline",
    reactors = parse(Int, get(OPT, "reactors", "1")),
    max_body_size = 200 * 1024 * 1024, body_in_memory = 200 * 1024 * 1024,
    before_body = head -> path(uri(head)) == "/upload/stream" ? Stream() : Buffer())
println("READY pid=$(getpid())")
wait(server)
