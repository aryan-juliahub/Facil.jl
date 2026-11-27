using Facil

const CANCELLED = Threads.Atomic{Int}(0)

function app(req)
    p = path(uri(req))
    if p == "/whoami"
        c = client_address(req)
        return "you are $(c.ip), port $(c.port)\n"
    elseif p == "/report"
        on_disconnect(() -> Threads.atomic_add!(CANCELLED, 1), req)
        for step in 1:50
            isconnected(req) || return Response(StatusCodes.SERVICE_UNAVAILABLE)
            Facil.sleep(0.1)                 # one slice of slow work
        end
        return "report ready\n"
    elseif p == "/cancelled"
        return "$(CANCELLED[]) report(s) cancelled\n"
    end
    Response(StatusCodes.NOT_FOUND)
end

serve(app, "127.0.0.1", 8080)
