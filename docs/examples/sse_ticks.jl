using Facil

function events(req)
    sse(req) do s
        # A reconnecting client says where it stopped.
        n = something(tryparse(Int, something(last_event_id(s), "0")), 0)
        write_event(s; retry = 2000)                    # reconnect after 2 s
        while isopen(s) && n < 5
            n += 1
            write_event(s; event = "tick", id = n, data = "tick $n") || break
            Facil.sleep(0.05)
        end
        write_event(s; event = "done", data = "bye")
    end                                                 # returning closes the connection
end

serve("127.0.0.1", 8080) do req
    path(uri(req)) == "/events" ? events(req) : Response(StatusCodes.NOT_FOUND)
end
