using Facil

# Every open event stream, so that other code can push to all of them.
const CLIENTS = Set{SSEStream}()
const CLIENTS_LOCK = ReentrantLock()

function broadcast(event, data)
    for s in lock(() -> collect(CLIENTS), CLIENTS_LOCK)
        write_event(s; event, data)
    end
end

function feed(req)
    sse(req) do s
        lock(() -> push!(CLIENTS, s), CLIENTS_LOCK)
        try
            while isopen(s)
                Facil.sleep(15)
                Facil.write_comment(s, "keep-alive")   # proxies drop silent connections
            end
        finally
            lock(() -> delete!(CLIENTS, s), CLIENTS_LOCK)
        end
    end
end

serve("127.0.0.1", 8080) do req
    m, p = method(req), path(uri(req))
    if m == Methods.GET && p == "/feed"
        feed(req)
    elseif m == Methods.POST && p == "/publish"
        broadcast("message", body(req))
        Response(StatusCodes.ACCEPTED)
    else
        Response(StatusCodes.NOT_FOUND)
    end
end
