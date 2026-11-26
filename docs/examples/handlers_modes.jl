using Facil

# Never waits: safe to run on the reactor thread.
serve!("127.0.0.1", 8081; inline = true) do req
    Response(StatusCodes.OK, "pong")
end

# Waits (here it sleeps; in a real service, a database or another API).
serve("127.0.0.1", 8080) do req
    Facil.sleep(0.05)
    Response(StatusCodes.OK, "done on thread $(Threads.threadid())")
end
