using Facil

# `kill <pid>` (SIGTERM) stops accepting, gives requests in progress up to
# 5 seconds to finish, then exits.
serve("127.0.0.1", 8080; shutdown_grace = 5, verbose = true) do req
    Facil.sleep(1.0)
    Response(StatusCodes.OK, "finished")
end
