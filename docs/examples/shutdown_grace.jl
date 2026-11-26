using Facil

const SERVER = Ref{Server}()

function app(req)
    p = path(uri(req))
    if p == "/report"
        Facil.sleep(1.0)                      # a request that takes a while
        Response(StatusCodes.OK, "report done")
    elseif p == "/shutdown" && method(req) == Methods.POST
        # Returns at once: stop accepting, let requests in progress finish
        # (up to 5 s), then close what is left.
        close(SERVER[]; grace = 5)
        Response(StatusCodes.ACCEPTED, "shutting down")
    else
        Response(StatusCodes.OK, "ok")
    end
end

SERVER[] = serve!(app, "127.0.0.1", 8080)
wait(SERVER[])
println("server closed; cleaning up")
