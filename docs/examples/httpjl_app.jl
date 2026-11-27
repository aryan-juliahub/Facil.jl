using Facil

function app(req::Request)
    if method(req) == Methods.GET && path(uri(req)) == "/hello"
        name = query_param(req, "name"; default = "world")
        Response(StatusCodes.OK, "hello $name"; headers = [header.CONTENT_TYPE => "text/plain"])
    elseif method(req) == Methods.POST && path(uri(req)) == "/echo"
        ct = get(headers(req), header.CONTENT_TYPE, hv"application/octet-stream")
        Response(StatusCodes.OK, body(req); headers = [header.CONTENT_TYPE => ct])
    else
        Response(StatusCodes.NOT_FOUND, "not found")
    end
end

serve(app, "127.0.0.1", 8080)
