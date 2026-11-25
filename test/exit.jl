# A process exits promptly with work still open. Ports 3950-3959.

module ExitTests

using Test

const EXIT_PORTS = 3950:3959
listening(p) = !isempty(readchomp(ignorestatus(`lsof -nP -t -iTCP:$p -sTCP:LISTEN`)))
function free_port()
    i = findfirst(!listening, EXIT_PORTS)
    i === nothing ? error("no free port in $EXIT_PORTS") : EXIT_PORTS[i]
end

const SCRIPT = raw"""
using Facil, Sockets
case = ARGS[1]; port = parse(Int, ARGS[2])
ws_req = "GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" *
         "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
socks = []
function open_req(req; wait_status = true)
    s = connect("127.0.0.1", port)
    write(s, req)
    wait_status && readline(s)
    push!(socks, s)
end
if case in ("subscribe", "all")
    subscribe(m -> nothing, "a")
    subscribe(m -> nothing, "b"; spawn = true)
    publish("a", "x")
end
case in ("every", "all") && every(() -> true, 10)
if !(case in ("subscribe", "every"))
    serve!("127.0.0.1", port) do req
        p = path(uri(req))
        p == "/ws" && return websocket(req; on_open = ws -> subscribe(ws, "a"))
        p == "/sse" && return sse(s -> (write_event(s; data = "a"); Base.sleep(1000)), req)
        p == "/stream" && return stream(io -> (write(io, "a"); flush(io); Base.sleep(1000)), req)
        p == "/park" && Base.sleep(1000)
        Response(StatusCodes.OK, "ok")
    end
    case in ("ws", "all") && open_req(ws_req)
    case in ("sse", "all") && open_req("GET /sse HTTP/1.1\r\nHost: x\r\n\r\n")
    case in ("stream", "all") && open_req("GET /stream HTTP/1.1\r\nHost: x\r\n\r\n")
    case in ("park", "all") && open_req("GET /park HTTP/1.1\r\nHost: x\r\n\r\n"; wait_status = false)
    Base.sleep(0.3)
end
println("READY")
"""

# Seconds from the end of the script to process exit, or `nothing` if it failed or hung.
function exit_time(case)
    cmd = `$(Base.julia_cmd()) -t 4 --project=$(Base.active_project()) --startup-file=no -e $SCRIPT $case $(free_port())`
    out = Pipe()
    proc = run(pipeline(ignorestatus(cmd); stdout = out, stderr = devnull); wait = false)
    close(out.in)
    ready = readline(out) == "READY"
    t0 = time()
    status = timedwait(() -> process_exited(proc), 30.0; pollint = 0.02)
    status === :ok || (kill(proc, Base.SIGKILL); wait(proc))
    ready && status === :ok && proc.exitcode == 0 ? time() - t0 : nothing
end

@testset "exit with open work" begin
    for case in ("subscribe", "every", "ws", "sse", "stream", "park", "all")
        @testset "$case" begin
            t = exit_time(case)
            @test t !== nothing && t < 5
        end
    end
end

end
