using Facil

const STARTED = time()

function app(req)
    p = path(uri(req))
    p == "/health" && return Response(StatusCodes.OK, "ok")
    p == "/" && return Response(StatusCodes.OK, "up for $(round(Int, time() - STARTED)) s\n")
    Response(StatusCodes.NOT_FOUND, "not found\n")
end

# Compile the handler before the first client arrives.
app(Request(Methods.GET, "/health", ""))

host = get(ENV, "HOST", "127.0.0.1")
port = parse(Int, get(ENV, "PORT", "8080"))

serve(app, host, port;
      verbose = true,          # a start-up line on stderr with the address, threads and limits
      shutdown_grace = 20,     # seconds for requests in flight when SIGTERM arrives
      max_body_size = 1 << 20, # this service takes no large uploads
      timeout = 30)            # idle keep-alive connections are closed after 30 s
