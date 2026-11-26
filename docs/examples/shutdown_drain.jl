using Facil

const SERVER = Ref{Server}()
const DRAIN_TOKEN = get(ENV, "DRAIN_TOKEN", "change-me")

function app(req)
    if method(req) == Methods.POST && path(uri(req)) == "/admin/drain"
        get(headers(req), "x-drain-token", "") == DRAIN_TOKEN || return Response(StatusCodes.FORBIDDEN, "forbidden\n")
        # Close from a task of our own, a moment after this response has gone out.
        Facil.Timer(_ -> close(SERVER[]; grace = 20), 0.05)
        return Response(StatusCodes.ACCEPTED, "draining\n")
    end
    sleep(1.0)        # stands in for a database query or a call to another service
    Response(StatusCodes.OK, "finished\n")
end

SERVER[] = serve!(app, "127.0.0.1", 8080)
wait(SERVER[])        # returns once the drain is complete
println("drained; exiting")
