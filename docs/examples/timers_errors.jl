using Facil

const RUNS = Threads.Atomic{Int}(0)

# The third call throws: the error is logged to stderr and the timer stops.
const flaky = Facil.Timer(0.02; interval = 0.02) do timer
    n = Threads.atomic_add!(RUNS, 1) + 1
    n == 3 && error("tick $n failed")
end

# Catch errors yourself to keep a timer alive.
const steady = Facil.Timer(0.02; interval = 0.02) do timer
    try
        rand() < 0.5 && error("sometimes")
    catch e
        # handle or log the error here
    end
end

serve("127.0.0.1", 8080) do req
    Response(StatusCodes.OK, "flaky: $(RUNS[]) runs, open=$(isopen(flaky)); steady open=$(isopen(steady))")
end

close(steady)
