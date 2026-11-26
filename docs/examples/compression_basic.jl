using Facil

const PAGE = repeat("<p>hello</p>\n", 500)

serve("127.0.0.1", 8080; compress = true) do req
    p = path(uri(req))
    if p == "/"
        Response(StatusCodes.OK, PAGE; headers = [header.CONTENT_TYPE => "text/html; charset=utf-8"])
    elseif p == "/small"
        Response(StatusCodes.OK, "under 1 KiB, sent as is\n")
    elseif p == "/photo"
        Response(StatusCodes.OK, rand(UInt8, 4096); headers = [header.CONTENT_TYPE => "image/jpeg"])
    elseif p == "/lines"
        stream(req; headers = [header.CONTENT_TYPE => "text/plain; charset=utf-8"]) do io
            for i in 1:2000
                write(io, "line $i of a compressed stream\n")
            end
        end
    else
        Response(StatusCodes.NOT_FOUND)
    end
end
