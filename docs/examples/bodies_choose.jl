using Facil

function choose(head)
    p = path(uri(head))
    p == "/upload" && return Stream()
    p == "/import" && return Spool()
    method(head) == Methods.PUT && return Reject(405)
    head.content_length > 100_000 && return Reject(413)
    Buffer()
end

function app(req)
    p = path(uri(req))
    if p == "/upload"
        n = 0
        for chunk in body_chunks(req)
            n += length(chunk)
        end
        Response(StatusCodes.OK, "streamed $n bytes\n")
    elseif p == "/import"
        io = body_stream(req)
        Response(StatusCodes.OK, "spooled $(countlines(io)) lines\n")
    else
        Response(StatusCodes.OK, "buffered $(sizeof(body(req))) bytes\n")
    end
end

serve(app, "127.0.0.1", 8080; before_body = choose, max_body_size = 1024^3)
