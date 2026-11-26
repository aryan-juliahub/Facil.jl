using Facil

serve("127.0.0.1", 8080) do req
    p = path(uri(req))
    p == "/throw" && error("database unavailable")
    p == "/number" && return 42          # neither a Response nor a String
    Response(StatusCodes.OK, "ok")
end
