# Temporary CI repro: GC during load with large Vector bodies.
using Facil
src = read(joinpath(@__DIR__, "..", "..", "test", "server.jl"), String)
i = findfirst("const CLIENT_JS = raw\"\"\"\n", src); j = findnext("\n\"\"\"\n", src, last(i))
js = joinpath(mktempdir(), "client.js"); write(js, src[last(i)+1:first(j)])
mode = ARGS[1]
Facil.CI1_DBG_NOSAFE[] = mode == "nosafe"
const KEEP = Any[]
const KEEP_LOCK = ReentrantLock()
SEQ = Threads.Atomic{Int}(0)
function fresh(n::Int, seq::Int)
    v = Vector{UInt8}(undef, n)
    fill!(v, seq % UInt8)
    for k in 0:min(7, n - 1)
        v[k+1] = ((seq >>> (8k)) & 0xff) % UInt8
    end
    v
end
function app(req)
    p = path(uri(req))
    n = parse(Int, p[8:end])
    b = fresh(n, Threads.atomic_add!(SEQ, 1) + 1)
    mode == "keep" && lock(() -> push!(KEEP, b), KEEP_LOCK)
    Response(StatusCodes.OK, mode == "string" ? String(b) : b)
end
srv = serve!(app, "127.0.0.1", 3655; inline = mode == "inline")
for round in 1:3
    out = IOBuffer()
    pr = run(pipeline(`node $js load 3655 32 100000 1024,16384,65536,131072,4096,200000`; stdout = out); wait = false)
    n = 0
    while process_running(pr)
        junk = [Vector{UInt8}(undef, rand(1:300_000)) for _ in 1:8]
        mode == "nogc" || GC.gc(rand(Bool))
        n += 1
        sleep(0.002)
    end
    wait(pr)
    println("round $round: ", String(take!(out)), " gcs=$n pinned=", Facil.pinned_bodies())
end
close(srv); wait(srv)
println("DONE")
