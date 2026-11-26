using Facil

function work(req)
    p = path(uri(req))
    if p == "/wait"
        Facil.sleep(0.2)                      # waiting: fine on a worker task
    elseif p == "/compute"
        sum(sqrt(i) for i in 1:20_000_000)    # CPU work: occupies one thread
    end
    Response(StatusCodes.OK, "$(p) ran on thread $(Threads.threadid())")
end

serve(work, "127.0.0.1", 8080)
