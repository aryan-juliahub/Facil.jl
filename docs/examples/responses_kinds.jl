using Facil

const PNG_PIXEL = UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]

function app(req)
    p = path(uri(req))
    if p == "/text"
        "a plain String is a 200 text/plain response\n"
    elseif p == "/html"
        Response(StatusCodes.OK, "<h1>hello</h1>\n"; headers = [header.CONTENT_TYPE => "text/html; charset=utf-8"])
    elseif p == "/bytes"
        Response(StatusCodes.OK, PNG_PIXEL; headers = [header.CONTENT_TYPE => "image/png"])
    elseif p == "/created"
        Response(StatusCodes.CREATED, "made\n"; headers = [header.LOCATION => "/things/1", "x-request-id" => "42"])
    elseif p == "/empty"
        Response(StatusCodes.NO_CONTENT)
    elseif p == "/old"
        Response(StatusCodes.MOVED_PERMANENTLY; headers = [header.LOCATION => "/text"])
    elseif p == "/cookies"
        res = Response(StatusCodes.OK, "two cookies\n")
        append!(headers(res), header.SET_COOKIE, "a=1; Path=/")
        append!(headers(res), header.SET_COOKIE, "b=2; Path=/")
        res
    elseif p == "/busy"
        Response(503, "an integer status works when a body follows\n"; headers = [header.RETRY_AFTER => "30"])
    elseif p == "/boom"
        error("handlers that throw give a 500")
    else
        Response(StatusCodes.NOT_FOUND, "no such page\n")
    end
end

serve(app, "127.0.0.1", 8080)
