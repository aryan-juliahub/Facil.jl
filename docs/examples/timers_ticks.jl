using Facil

const STARTED = time()
const TICKS = Threads.Atomic{Int}(0)

# `every`: the function runs every 100 ms until it returns `false`.
const ticker = every(100) do
    Threads.atomic_add!(TICKS, 1)
    true
end

# `Facil.Timer`: once after a delay (seconds), or repeating with `interval`.
const READY = Threads.Atomic{Bool}(false)
Facil.Timer(_ -> READY[] = true, 0.25)

serve("127.0.0.1", 8080) do req
    p = path(uri(req))
    if p == "/slow"
        # A task handler may wait; other requests are served meanwhile.
        Facil.sleep(0.05)
        Response(StatusCodes.OK, "waited 50 ms")
    elseif p == "/stop"
        close(ticker)
        Response(StatusCodes.OK, "ticker stopped at $(TICKS[])")
    else
        Response(StatusCodes.OK, "ticks=$(TICKS[]) ready=$(READY[]) ticker=$(isopen(ticker) ? "running" : "stopped")")
    end
end

close(ticker)
