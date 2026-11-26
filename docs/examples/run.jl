# Runs every program in docs/examples against its check in docs/examples/checks.
# An example is the file a reader copies; here its `serve`/`serve!` calls listen
# on a free port instead of the one written in the file.
module DocExamples

using Test, Sockets
import Facil

export output, http, raw_request, curl, ws_connect, ws_send, ws_recv, ws_close, sse_open, sse_next, wait_until, base_url

const DIR = @__DIR__
const CHECKS = joinpath(DIR, "checks")

mutable struct Example
    name::String
    servers::Vector{Any}
    ports::Vector{Int}
    serving::Base.Event
    proc::Any
    output::IOBuffer
    mod::Module
end
Example(name) = Example(name, Any[], Int[], Base.Event(), nothing, IOBuffer(), Main)

Base.getproperty(ex::Example, f::Symbol) =
    f === :port ? first(getfield(ex, :ports)) : f === :server ? first(getfield(ex, :servers)) : getfield(ex, f)

# ---- running an example

function free_port_args(args)
    host = "127.0.0.1"
    for a in args
        a isa AbstractString && (host = String(a))
    end
    host
end

# The port written in the example becomes 0 (any free port), unless it is the
# port of a server this example already started: that is asked for on purpose.
function start!(ex::Example, f, args...; kw...)
    asked = something(findfirst(a -> a isa Integer, args), 0)
    p = asked != 0 && args[asked] in ex.ports ? args[asked] : 0
    srv = Facil.serve!(f, free_port_args(args), p; kw...)
    push!(ex.servers, srv)
    push!(ex.ports, Facil.port(srv))
    srv
end

function blocking_serve(ex::Example, f, args...; kw...)
    srv = start!(ex, f, args...; kw...)
    notify(ex.serving)
    wait(srv)
    nothing
end

function sandbox(ex::Example)
    m = Module(Symbol("DocExample_", replace(ex.name, r"\W" => "_")))
    Core.eval(m, :(include(p) = Base.include($m, p)))
    Core.eval(m, :(eval(x) = Core.eval($m, x)))
    Core.eval(m, :(serve(f, args...; kw...) = $blocking_serve($ex, f, args...; kw...)))
    Core.eval(m, :(serve!(f, args...; kw...) = $start!($ex, f, args...; kw...)))
    m
end

function directives(checkfile)
    d = Dict{String,String}()
    for line in eachline(checkfile)
        m = match(r"^#\s*(mode|needs|threads|env|servers):\s*(.*)$", line)
        m === nothing ? (startswith(line, "#") || break) : (d[m[1]] = strip(m[2]))
    end
    d
end

const PROCESS_SHIM = """
import Facil
# One write per line, as Facil's own log does: a line printed in pieces can be
# split by a log line from another thread, and its port would be missed.
__mark(line) = (ccall(:write, Cssize_t, (Cint, Ptr{UInt8}, Csize_t), 2, line, sizeof(line)); nothing)
function __start(f, args...; kw...)
    host = "127.0.0.1"
    for a in args
        a isa AbstractString && (host = String(a))
    end
    srv = Facil.serve!(f, host, 0; kw...)
    __mark("DOCEXAMPLE PORT \$(Facil.port(srv))\n")
    srv
end
serve!(f, args...; kw...) = __start(f, args...; kw...)
function serve(f, args...; kw...)
    srv = __start(f, args...; kw...)
    __mark("DOCEXAMPLE SERVING\n")
    Facil.foreground!(srv, 1)
    try
        wait(srv)
    catch e
        e isa InterruptException || rethrow()
    finally
        Facil.foreground!(srv, -1)
        close(srv)
    end
    wait(srv)
    nothing
end
include(ARGS[1])
"""

function start_process!(ex::Example, file, d)
    threads = get(d, "threads", "4")
    cmd = `$(Base.julia_cmd()) -t $threads --startup-file=no --project=$(Base.active_project()) -e $PROCESS_SHIM $file`
    env = copy(ENV)
    for kv in split(get(d, "env", ""))
        k, v = split(kv, '='; limit = 2)
        env[k] = replace(v, "@repo" => dirname(dirname(DIR)))
    end
    err = Pipe()
    ex.proc = run(pipeline(setenv(cmd, env); stdout = err, stderr = err); wait = false)
    close(err.in)
    @async for line in eachline(err)
        m = match(r"^DOCEXAMPLE PORT (\d+)", line)
        if line == "DOCEXAMPLE SERVING"
            notify(ex.serving)
        elseif m === nothing
            println(ex.output, line)
        else
            push!(ex.ports, parse(Int, m[1]))
            notify(ex.serving)
        end
    end
    ex
end

"The text the example process has written to stdout and stderr so far."
output(ex::Example) = String(copy(ex.output.data[1:ex.output.size]))

function run_example(name::AbstractString; strict::Bool = true)
    file = joinpath(DIR, name * ".jl")
    check = joinpath(CHECKS, name * ".jl")
    isfile(check) || error("docs/examples/$name.jl has no check in docs/examples/checks/$name.jl")
    d = directives(check)
    for pkg in split(get(d, "needs", ""))
        if Base.find_package(String(pkg)) === nothing
            strict && error("example $name needs $pkg, which is not in this environment")
            @info "skipping docs example $name: $pkg is not installed"
            return nothing
        end
    end
    ex = Example(name)
    task = nothing
    # `# servers: N` is for examples that block in something other than `serve`
    # (`wait(server)`): they count as started once N servers listen.
    nservers = parse(Int, get(d, "servers", "0"))
    started() = nservers > 0 ? length(ex.ports) >= nservers : ex.serving.set
    settled = if get(d, "mode", "inline") == "process"
        start_process!(ex, file, d)
        () -> started() || process_exited(ex.proc)
    else
        ex.mod = sandbox(ex)
        task = @async Base.include($(ex.mod), $file)
        () -> started() || istaskdone(task)
    end
    try
        timedwait(settled, 180.0; pollint = 0.02) === :ok || error("example $name did not start within 180 s")
        nservers > 0 && sleep(0.2)
        task !== nothing && istaskfailed(task) && fetch(task)
        m = Module(:DocExampleCheck)
        Core.eval(m, :(using Test, Sockets, Facil))
        for n in names(@__MODULE__)
            n === nameof(@__MODULE__) || Core.eval(m, :(const $n = $(getfield(@__MODULE__, n))))
        end
        Core.eval(m, :(const DocExamples = $(@__MODULE__)))
        Core.eval(m, :(const ex = $ex))
        Core.eval(m, :(const example = $(ex.mod)))
        @testset "$name" begin
            Base.include(m, check)
        end
    finally
        for s in ex.servers
            close(s)
        end
        foreach(wait, ex.servers)
        if ex.proc !== nothing && !process_exited(ex.proc)
            kill(ex.proc)
            timedwait(() -> process_exited(ex.proc), 15.0) === :ok || kill(ex.proc, Base.SIGKILL)
        end
        if task !== nothing
            timedwait(() -> istaskdone(task), 30.0) === :ok || error("example $name did not return after its servers closed")
            istaskfailed(task) && fetch(task)
        end
    end
    nothing
end

examples() = sort!([first(splitext(f)) for f in readdir(DIR) if endswith(f, ".jl") && f != "run.jl"])

"""
    run_all(; only = nothing, strict = true)

Runs every example (or those named in `only`). With `strict = false` an example
whose `# needs:` packages are not installed is skipped instead of failing.
"""
function run_all(; only = nothing, strict::Bool = true)
    names = only === nothing ? examples() : collect(String, only)
    orphans = setdiff([first(splitext(f)) for f in readdir(CHECKS) if endswith(f, ".jl")], examples())
    isempty(orphans) || error("checks without an example: $(join(orphans, ", "))")
    @testset "docs examples" begin
        only === nothing && readme_blocks()
        for name in names
            run_example(name; strict)
        end
    end
end

# Every `julia` code block in the README is, word for word, one of the examples.
function readme_blocks()
    sources = Set(rstrip(read(joinpath(DIR, n * ".jl"), String)) for n in examples())
    readme = read(joinpath(dirname(dirname(DIR)), "README.md"), String)
    blocks = [rstrip(m[1]) for m in eachmatch(r"```julia\n(.*?)```"s, readme)]
    @testset "README" begin
        @test !isempty(blocks)
        for b in blocks
            @test b in sources
        end
    end
end

# ---- a small HTTP client for the checks

base_url(ex::Example, i::Integer = 1) = "http://127.0.0.1:$(ex.ports[i])"
portof(x::Example) = x.port
portof(x::Integer) = Int(x)

function dechunk(data::Vector{UInt8})
    out = UInt8[]
    i = 1
    while i <= length(data)
        j = findnext(==(UInt8('\n')), data, i)
        j === nothing && break
        n = parse(Int, strip(first(split(String(data[i:j-1]), ';'))); base = 16)
        n == 0 && break
        append!(out, data[j+1:j+n])
        i = j + n + 3
    end
    out
end

"""
    http(ex_or_port, method, target; headers = [], body = "", version = "1.1")

One request on its own connection. Returns `(status, headers, body)`: the status
as an `Int`, header names lowercased in a `Dict` (the last value of a repeated
name), and the body as a `String` with chunked framing removed.
"""
function http(to, method::AbstractString, target::AbstractString; headers = [], body = "", version = "1.1")
    s = connect("127.0.0.1", portof(to))
    io = IOBuffer()
    print(io, method, ' ', target, " HTTP/", version, "\r\nHost: 127.0.0.1\r\nConnection: close\r\n")
    for (k, v) in headers
        print(io, k, ": ", v, "\r\n")
    end
    sizeof(body) > 0 && print(io, "Content-Length: ", sizeof(body), "\r\n")
    print(io, "\r\n")
    write(io, body)
    write(s, take!(io))
    data = read(s)
    close(s)
    parse_response(data; head_only = method == "HEAD")
end

function parse_response(data::Vector{UInt8}; head_only::Bool = false)
    r = findfirst(codeunits("\r\n\r\n"), data)
    r === nothing && error("no response head in $(repr(String(copy(data))))")
    lines = split(String(data[1:first(r)-1]), "\r\n")
    status = parse(Int, split(lines[1], ' ')[2])
    hs = Dict{String,String}()
    for l in lines[2:end]
        k, v = split(l, ':'; limit = 2)
        hs[lowercase(strip(k))] = strip(v)
    end
    rest = data[last(r)+1:end]
    payload = head_only ? UInt8[] : occursin("chunked", get(hs, "transfer-encoding", "")) ? dechunk(rest) : rest
    (status = status, headers = hs, body = String(payload))
end

"Writes `text` on a new connection and returns everything the server sends within `wait` seconds."
function raw_request(to, text; wait::Real = 0.5)
    s = connect("127.0.0.1", portof(to))
    write(s, text)
    buf = UInt8[]
    t = @async while !eof(s)
        append!(buf, readavailable(s))
    end
    timedwait(() -> istaskdone(t), wait)
    close(s)
    String(buf)
end

"`curl -s args...`; returns its standard output."
curl(args...) = read(`curl -s --max-time 30 $(collect(String, args))`, String)

function wait_until(f; timeout::Real = 10)
    timedwait(f, Float64(timeout); pollint = 0.01) === :ok
end

# ---- WebSocket client (text and binary messages, no extensions)

struct WSClient
    sock::TCPSocket
    head::String
end

function ws_connect(to, target = "/"; headers = [])
    s = connect("127.0.0.1", portof(to))
    io = IOBuffer()
    print(io, "GET ", target, " HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n",
          "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n")
    for (k, v) in headers
        print(io, k, ": ", v, "\r\n")
    end
    print(io, "\r\n")
    write(s, take!(io))
    head = readuntil(s, "\r\n\r\n")
    startswith(head, "HTTP/1.1 101") || (close(s); error("WebSocket upgrade refused: $(first(split(head, "\r\n")))"))
    WSClient(s, head)
end

function ws_frame(opcode::UInt8, payload::Vector{UInt8})
    n = length(payload)
    io = IOBuffer()
    write(io, 0x80 | opcode)
    n < 126 ? write(io, 0x80 | UInt8(n)) : n < 65536 ? write(io, 0xfe, hton(UInt16(n))) : write(io, 0xff, hton(UInt64(n)))
    mask = rand(UInt8, 4)
    write(io, mask)
    write(io, UInt8[payload[i] ⊻ mask[(i-1)%4+1] for i in 1:n])
    take!(io)
end

ws_send(c::WSClient, msg::AbstractString) = (write(c.sock, ws_frame(0x01, Vector{UInt8}(codeunits(msg)))); nothing)
ws_send(c::WSClient, msg::Vector{UInt8}) = (write(c.sock, ws_frame(0x02, msg)); nothing)

"The next message: a `String`, a `Vector{UInt8}`, or `(:close, code)` when the server closes."
function ws_recv(c::WSClient; timeout::Real = 10)
    t = @async begin
        parts = UInt8[]
        op = 0x00
        while true
            b = read(c.sock, 2)
            o = b[1] & 0x0f
            n = Int(b[2] & 0x7f)
            n == 126 && (n = Int(ntoh(read(c.sock, UInt16))))
            n == 127 && (n = Int(ntoh(read(c.sock, UInt64))))
            p = read(c.sock, n)
            o == 0x08 && return (:close, n >= 2 ? Int(p[1]) << 8 | p[2] : 0)
            o in (0x09, 0x0a) && continue
            o != 0x00 && (op = o)
            append!(parts, p)
            b[1] & 0x80 != 0 && break
        end
        op == 0x01 ? String(parts) : parts
    end
    timedwait(() -> istaskdone(t), Float64(timeout)) === :ok || error("no WebSocket message within $timeout s")
    fetch(t)
end

function ws_close(c::WSClient; code::Integer = 1000)
    try
        write(c.sock, ws_frame(0x08, UInt8[code >> 8, code & 0xff]))
    catch
    end
    close(c.sock)
    nothing
end

# ---- server-sent events client

function sse_open(to, target = "/"; headers = [])
    s = connect("127.0.0.1", portof(to))
    io = IOBuffer()
    print(io, "GET ", target, " HTTP/1.1\r\nHost: 127.0.0.1\r\nAccept: text/event-stream\r\n")
    for (k, v) in headers
        print(io, k, ": ", v, "\r\n")
    end
    print(io, "\r\n")
    write(s, take!(io))
    head = readuntil(s, "\r\n\r\n")
    (sock = s, head = head)
end

"The next event as a `Dict` of its fields (`data` lines joined by newlines); comments are skipped."
function sse_next(c; timeout::Real = 10)
    t = @async begin
        while true
            ev = Dict{String,String}()
            while true
                line = readline(c.sock)
                isempty(line) && break
                startswith(line, ":") && continue
                k, v = occursin(':', line) ? split(line, ':'; limit = 2) : (line, "")
                v = startswith(v, " ") ? v[2:end] : v
                ev[k] = haskey(ev, k) && k == "data" ? ev[k] * "\n" * v : String(v)
            end
            isempty(ev) || return ev
            eof(c.sock) && return ev
        end
    end
    timedwait(() -> istaskdone(t), Float64(timeout)) === :ok || error("no SSE event within $timeout s")
    fetch(t)
end

end # module
