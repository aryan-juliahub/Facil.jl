using Facil

# Counts the lines of an upload of any size while holding at most
# `high_water` bytes of it in memory.
serve("127.0.0.1", 8080; before_body = head -> Stream(; high_water = 256 * 1024),
      max_body_size = 10 * 1024^3) do req
    io = body_stream(req)
    lines = 0
    try
        while !eof(io)
            readline(io)
            lines += 1
        end
    catch e
        e isa Facil.BodyAborted || rethrow()
        @warn "upload abandoned" lines
        return Response(StatusCodes.BAD_REQUEST)
    end
    Response(StatusCodes.OK, "$lines lines\n")
end
