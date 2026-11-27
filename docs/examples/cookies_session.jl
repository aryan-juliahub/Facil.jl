using Facil

serve("127.0.0.1", 8080) do req
    p = path(uri(req))
    if p == "/login"
        res = Response(StatusCodes.OK, "logged in\n")
        set_cookie!(res, "sid", "abc123"; path = "/", http_only = true, same_site = :lax, max_age = 3600)
        set_cookie!(res, "theme", "dark mode"; path = "/", escape = true)
        res
    elseif p == "/logout"
        delete_cookie!(Response(StatusCodes.OK, "logged out\n"), "sid"; path = "/")
    else
        c = cookies(req; unescape = true)
        sid = get(c, "sid", nothing)
        sid === nothing && return Response(StatusCodes.UNAUTHORIZED, "no session\n")
        Response(StatusCodes.OK, "session $sid, theme $(get(c, "theme", "light"))\n")
    end
end
