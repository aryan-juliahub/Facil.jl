using Facil

# Decide what to do with a body as soon as its head has arrived, before any of
# it is read. Only /upload takes large bodies, and only with a declared length.
function before_body(head)
    if path(uri(head)) == "/upload"
        Facil.ischunked(head) && return Reject(411)                  # Length Required
        head.content_length > 8 * 1024 * 1024 && return Reject(413)
        return Spool()                                              # to a temporary file, not memory
    end
    get(headers(head), header.CONTENT_TYPE, nothing) == "application/json" || return Reject(415)
    Buffer()
end

function app(req)
    if path(uri(req)) == "/upload"
        Response(StatusCodes.OK, "stored $(filesize(body_stream(req))) bytes\n")
    else
        Response(StatusCodes.OK, "got $(sizeof(body(req))) bytes of JSON\n")
    end
end

serve(app, "127.0.0.1", 8080;
      before_body,
      max_header_size = 8 * 1024,        # request head: 431 above 8 KiB (default 32 KiB)
      max_body_size = 16 * 1024 * 1024,  # any body: 413 above 16 MiB (default 50 MiB)
      body_in_memory = 64 * 1024,        # Buffer() bodies: 413 above 64 KiB (default 16 MiB)
      header_timeout = 5,                # 408 if the head takes longer than 5 s (default 30)
      timeout = 15,                      # idle keep-alive connections close after 15 s (default 40)
      max_pending_output = 1024 * 1024)  # drop clients that stop reading with 1 MiB unsent (default 16 MiB)
