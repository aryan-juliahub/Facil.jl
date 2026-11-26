using Facil

function app(req)
    p = path(uri(req))
    if p == "/text"
        "a String is sent as 200 text/plain"
    elseif p == "/json"
        Response(StatusCodes.OK, """{"ok":true}"""; headers = [header.CONTENT_TYPE => "application/json"])
    elseif p == "/bytes"
        Response(StatusCodes.OK, UInt8[0x89, 0x50, 0x4e, 0x47])
    elseif p == "/created"
        Response(201, "made"; headers = [header.LOCATION => "/things/1"])
    elseif p == "/empty"
        Response(StatusCodes.NO_CONTENT)
    elseif p == "/boom"
        error("this handler has a bug")
    else
        Response(StatusCodes.NOT_FOUND, "no such page\n")
    end
end

serve(app, "127.0.0.1", 8080)
