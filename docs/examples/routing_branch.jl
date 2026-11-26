using Facil

function app(req)
    m, p = method(req), path(uri(req))
    if p == "/"
        m == Methods.GET || return not_allowed("GET")
        Response(StatusCodes.OK, "home\n")
    elseif startswith(p, "/users/")
        m == Methods.GET || return not_allowed("GET")
        id = tryparse(Int, chopprefix(p, "/users/"))
        id === nothing && return Response(StatusCodes.BAD_REQUEST, "bad id\n")
        Response(StatusCodes.OK, "user $id\n")
    else
        Response(StatusCodes.NOT_FOUND, "not found\n")
    end
end

not_allowed(allow) = Response(StatusCodes.METHOD_NOT_ALLOWED, "method not allowed\n"; headers = [header.ALLOW => allow])

serve(app, "127.0.0.1", 8080)
