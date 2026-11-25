# Threads, task handlers and inline handlers

facil.io runs its event loop (the *reactor*) on a thread Facil creates. Julia
handlers run in one of two ways:

| | `inline = false` (default) | `inline = true` |
|---|---|---|
| Where the handler runs | its own Julia task (`Threads.@spawn`) | the reactor thread, inside the callback |
| May block (I/O, `Facil.sleep`, locks) | yes | no: a blocking handler stalls every connection on that reactor |
| Cost | a pause, spawn and resume per request | none |
| Needs | Julia started with more than one thread | nothing |

With one Julia thread, task handlers cannot run beside the reactor, so handlers
run inline whatever `inline` says (`verbose = true` prints a note). Start Julia
with threads for task handlers:

```sh
julia -t 4 --project server.jl
```

Two servers in one process share the reactor; one may be inline and the other not:

```julia
using Facil

serve!("127.0.0.1", 8081; inline = true) do req
    Response(StatusCodes.OK, "inline")
end

serve("127.0.0.1", 8080) do req
    Facil.sleep(0.05)
    Response(StatusCodes.OK, "task on thread $(Threads.threadid())")
end
```

## Reactor threads

`reactors = N` runs the reactor on `N` threads. It is process-wide: the first
server fixes it, and a later server asking for a different number throws. HTTPS
servers need `reactors = 1`.

## Idle CPU

Task handlers run on a small pool of worker tasks (one fewer than the default
threadpool, so a thread is always free for tasks that yielded). Between
requests a worker waits in C rather than in Julia's scheduler, so it uses no
CPU; under heavy load it spins briefly to take the next request without a
wake-up.

A task handler costs two hand-offs between threads per request (reactor to
worker and back), and a task reading a streamed body pays them again per chunk.
At heavy load the workers stay awake and this is cheap; at light, steady load
each hand-off wakes a sleeping thread, so a task-handler server uses several
times Node's CPU and has a higher p99 (scoreboard rows 31-p99 and 31-cpu, an
approved exception; see [Known limits](../limits.md)).

- For handlers that do not block, use `inline = true`: it beats Node on CPU and
  latency at every load.
- For uploads, use `Stream(on_chunk)` (see [Request bodies](bodies.md)): each
  chunk is handled on the reactor with no hand-off, which also beats Node.

## `Facil.sleep` and timers

`Base.sleep` is coarse for short waits (about 2.5 ms for `sleep(0.001)` on
macOS). `Facil.sleep(seconds)` is timed by a C timer thread to within tens of
microseconds and lets other tasks run meanwhile. Use it in task handlers. In an
inline handler it blocks the reactor thread.

`every(f, ms)` calls `f()` every `ms` milliseconds on a Julia task until `f`
returns `false` or the timer is closed. `Facil.Timer(callback, delay; interval)`
is the general form.

```julia
using Facil

const ticks = Threads.Atomic{Int}(0)
every(100) do
    Threads.atomic_add!(ticks, 1)
    true
end

serve("127.0.0.1", 8080) do req
    Response(StatusCodes.OK, "ticks: $(ticks[])")
end
```
