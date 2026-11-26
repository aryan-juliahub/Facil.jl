using Facil

const SERVER = Ref{Server}()

function metrics()
    """
    facil_connections $(Facil.connections(SERVER[]))
    facil_paused_requests $(Facil.paused_requests())
    facil_pending_bodies $(Facil.pending_bodies())
    facil_pinned_bodies $(Facil.pinned_bodies())
    facil_live_streams $(Facil.live_streams())
    facil_open_websockets $(Facil.open_websockets())
    """
end

function app(req)
    path(uri(req)) == "/metrics" && return Response(StatusCodes.OK, metrics())
    Response(StatusCodes.OK, "hello")
end

SERVER[] = serve!(app, "127.0.0.1", 8080)
wait(SERVER[])
