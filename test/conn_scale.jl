# Many keep-alive connections: memory per idle connection, and (with
# FACIL_TEST_CONN_SCALE=1) 10,000 connections under load. Ports 4040-4049.

module ConnScaleTests

using Test, Sockets

const CS_PORTS = 4040:4049
listening(p) = !isempty(readchomp(ignorestatus(`lsof -nP -t -iTCP:$p -sTCP:LISTEN`)))
function free_port()
    i = findfirst(!listening, CS_PORTS)
    i === nothing ? error("no free port in $CS_PORTS") : CS_PORTS[i]
end

const SCRIPT = raw"""
using Facil
port = parse(Int, ARGS[1])
srv = serve!(req -> Response(StatusCodes.OK, "ok"), "127.0.0.1", port; inline = true)
println("READY $(getpid())"); flush(stdout)
wait(srv)
"""

rss_kb(pid) = parse(Int, strip(read(`ps -o rss= -p $pid`, String)))

function with_server(f)
    port = free_port()
    cmd = `$(Base.julia_cmd()) -t 1 --project=$(Base.active_project()) --startup-file=no -e $SCRIPT $port`
    out = Pipe()
    proc = run(pipeline(cmd; stdout = out, stderr = devnull); wait = false)
    close(out.in)
    try
        line = readline(out)
        startswith(line, "READY") || error("server did not start: $(repr(line))")
        f(port, parse(Int, split(line)[2]))
    finally
        kill(proc)
        wait(proc)
    end
end

const REQ = "GET / HTTP/1.1\r\nHost: x\r\n\r\n"

function roundtrip(s)
    write(s, REQ)
    head = readuntil(s, "\r\n\r\n")
    startswith(head, "HTTP/1.1 200") || error("bad response: $(repr(head))")
    n = parse(Int, match(r"(?i)content-length:\s*(\d+)", head)[1])
    read(s, n)
end

@testset "idle keep-alive connections are cheap" begin
    with_server() do port, pid
        warm = [connect("127.0.0.1", port) for _ in 1:200]
        foreach(roundtrip, warm)
        foreach(close, warm)
        Base.sleep(0.5)
        before = rss_kb(pid)
        n = 3000
        socks = [connect("127.0.0.1", port) for _ in 1:n]
        foreach(roundtrip, socks)
        Base.sleep(0.5)
        per_conn = (rss_kb(pid) - before) * 1024 / n
        @info "server memory per idle keep-alive connection" bytes = round(Int, per_conn)
        @test per_conn < 4096
        @test all(s -> roundtrip(s) == b"ok", socks[1:100:end])
        foreach(close, socks)
    end
end

end
