using Facil

const HITS = Threads.Atomic{Int}(0)          # a counter: atomic, no lock needed

const LAST_SEEN = Dict{String,Float64}()     # anything else: guard it with a lock
const LAST_SEEN_LOCK = ReentrantLock()

serve("127.0.0.1", 8080) do req
    n = Threads.atomic_add!(HITS, 1) + 1
    who = String(get(headers(req), "x-client", "anonymous"))
    lock(LAST_SEEN_LOCK) do
        LAST_SEEN[who] = time()
    end
    Response(StatusCodes.OK, "request $n")
end
