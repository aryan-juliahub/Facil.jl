# The application, without the `serve` call, so that the server program, the
# tests and the sysimage warm-up script can all include it.
using Facil

const STARTED = time()

function app(req)
    p = path(uri(req))
    p == "/health" && return Response(StatusCodes.OK, "ok")
    p == "/" && return Response(StatusCodes.OK, "up for $(round(Int, time() - STARTED)) s\n")
    Response(StatusCodes.NOT_FOUND, "not found\n")
end
