# Server-sent events: framing, Last-Event-ID, writes from other tasks, client
# disconnects and the Accept: text/event-stream route.
module M6SSETests

using Facil, Test, Sockets
isdefined(Main, :M6Http) || Main.include(joinpath(@__DIR__, "m6_http.jl"))
using Main.M6Http
import Main.M6Http

const SSE_PORTS = 3770:3774
const SSE_STATE = (closed = Threads.Atomic{Int}(0), streams = Channel{Any}(16))

function sse_app(req)
    p = path(uri(req))
    if p == "/events"
        return sse(req; headers = ["x-sse" => "1"]) do s
            write_event(s; data = "first", retry = 1500)
            write_event(s; data = "two\nlines\r\nthree", event = "multi", id = 7)
            write_event(s, "last id $(something(last_event_id(s), "none"))")
            Facil.write_comment(s, "keep-alive")
            write_event(s; id = "only-id")
        end
    elseif startswith(p, "/held")
        return sse(req) do s
            put!(SSE_STATE.streams, (parse(Int, query(uri(req))), s))
            wait(s)
            Threads.atomic_add!(SSE_STATE.closed, 1)
        end
    elseif p == "/bad"
        return sse(req) do s
            write_event(s; event = "a\nb", data = "x")
        end
    end
    Response(StatusCodes.OK, "plain")
end

function read_until(s, marker; limit = 1 << 20)
    acc = UInt8[]
    while !occursin(marker, String(copy(acc)))
        eof(s) && error("connection closed before $(repr(marker))")
        append!(acc, readavailable(s))
        length(acc) > limit && error("marker not found")
    end
    String(acc)
end

@testset "sse" begin
    for inline in (false, true)
        srv = serve!(sse_app, SSE_PORTS[1 + inline]; inline)
        port = Facil.port(srv)
        try
            s, t = rawconn(port)
            send_raw(s, request("GET", "/events"; headers = ["Accept" => "text/event-stream", "Last-Event-ID" => "41"]))
            st, hs = M6Http.read_head(s)
            @test st == 200
            @test startswith(hs["content-type"], "text/event-stream")
            @test hs["x-sse"] == "1"
            @test !haskey(hs, "content-length")
            body = String(read(s))
            @test body == "retry: 1500\ndata: first\n\n" *
                          "event: multi\nid: 7\ndata: two\ndata: lines\ndata: three\n\n" *
                          "data: last id 41\n\n" *
                          ": keep-alive\n\n" *
                          "id: only-id\n\n"
            close(t); close(s)

            # without Accept: text/event-stream, and without Last-Event-ID
            s, t = rawconn(port)
            send_raw(s, request("GET", "/events"))
            M6Http.read_head(s)
            @test occursin("data: last id none\n", String(read(s)))
            close(t); close(s)

            # the plain route still answers on an SSE-accepting request
            r = get1(port, "/plain"; headers = ["Accept" => "text/event-stream"])
            @test r.status == 200 && String(r.body) == "plain"

            # invalid fields: the handler errors and the stream closes
            s, t = rawconn(port)
            send_raw(s, request("GET", "/bad"))
            M6Http.read_head(s)
            @test isempty(read(s))
            close(t); close(s)
        finally
            close(srv); wait(srv)
        end
    end

    @testset "held streams" begin
        srv = serve!(sse_app, SSE_PORTS[3])
        port = Facil.port(srv)
        try
            c0 = SSE_STATE.closed[]
            conns = [rawconn(port) for _ in 1:5]
            for (i, (s, _)) in enumerate(conns)
                send_raw(s, request("GET", "/held?$i"))
            end
            for (s, _) in conns
                M6Http.read_head(s)
            end
            streams = last.(sort([take!(SSE_STATE.streams) for _ in 1:5]; by = first))
            @test all(isopen, streams)
            # events written from other tasks, concurrently
            @sync for (i, st) in enumerate(streams)
                Threads.@spawn for k in 1:100
                    write_event(st; data = "s$i e$k", id = k)
                end
            end
            for (i, (s, _)) in enumerate(conns)
                txt = read_until(s, "id: 100\ndata: s$i e100\n\n")
                @test count("data: s$i e", txt) == 100
            end
            # a client that leaves: isopen turns false and wait(s) returns
            s1, t1 = conns[1]
            close(t1); close(s1)
            @test wait_until(() -> !isopen(streams[1]))
            @test wait_until(() -> SSE_STATE.closed[] == c0 + 1)
            @test write_event(streams[1], "late") == false
            # the server closing its side ends the others
            for st in streams[2:end]
                close(st)
            end
            for (s, t) in conns[2:end]
                @test endswith(String(read(s)), "")
                close(t); close(s)
            end
            @test wait_until(() -> SSE_STATE.closed[] == c0 + 5)
            @test wait_until(() -> Facil.live_streams() == 0)
        finally
            close(srv); wait(srv)
        end
    end

    @testset "arguments" begin
        req = Request{String}(; uri = "/x")
        @test_throws ArgumentError sse(s -> nothing, req; high_water = 0)
        st = Facil.SSEStream(nothing, 1024)
        @test_throws ArgumentError write_event(st)
        @test_throws ArgumentError write_event(st; id = "a\rb")
    end
end

end
