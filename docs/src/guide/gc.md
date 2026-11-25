# Garbage collection and latency tails

Every Julia garbage collection stops all threads, the reactor included, so
requests that arrive during a collection wait for it. Short collections are
invisible; the long ones show up as the slowest requests (p99.9 and the
maximum). This page lists what changes their length and how often they happen.

## What allocates per request

Facil allocates the `Request` it passes to your handler: the request object,
its `HeaderMap`, the path string and one string per header value (about 500
bytes for a small GET). Everything else comes from the handler: a `Response`
built from a vector of header pairs, for example, adds about 350 bytes. To see
what your handler allocates, run a short load and look at `Base.gc_num()`, or
record it with `Profile.Allocs.@profile`.

Two habits keep collections short:

- Do not keep per-request objects in globals (a "last request" slot, an
  unbounded cache). An object that is still referenced when a collection runs
  moves to the old generation, and old garbage is only freed by a full
  collection, which marks the whole heap.
- Reuse buffers for large temporary data instead of allocating them per request.

## Give the collector threads

Julia started with `-t 1` marks and sweeps with one GC thread. A server with
inline handlers often runs that way, and every pause is then several times
longer than it needs to be. Give the collector threads of its own; they are
idle between collections:

```sh
julia -t 1 --gcthreads=4 --project server.jl
# or
JULIA_NUM_GC_THREADS=4 julia -t 1 --project server.jl
```

With `-t 4` or more Julia already uses several GC threads.

## Heap headroom for large temporaries

Julia sizes the heap from what is live. A server with a small live heap whose
handlers allocate large temporaries (tens of kilobytes or more per request)
collects very often, and the object each collection finds still in use is
promoted and later needs a full collection. `gc_headroom` keeps a block of the
given size alive but never written, so the collector behaves as if the heap were
that much larger: fewer, slightly longer collections. It costs address space,
not memory.

```julia
serve!(handler, 8080; gc_headroom = 1 << 30)   # or Facil.gc_headroom!(1 << 30)
```

It is off by default because it does not help every load: with small
temporaries (around 10 KB per request) the rarer collections each have more to
sweep and p99.9 got worse in our measurements. Measure your own load before
keeping it.

## Measuring

`GC.enable_logging(true)` prints every pause with its kind (`incr` or `full`).
`Base.gc_num()` has counters for collections, full collections, mark and sweep
time; sample it once a second next to your latency figures to tell a GC pause
from other stalls.

## Measured

One reactor, inline handlers, 100 connections, macOS, Julia 1.13 (scoreboard
rows, median of 3 runs; milliseconds unless noted). Node.js 22 on the same
machine: 1.9, 0.14 / 0.66, 0.18 and 139k, 0.88.

| Load | `-t 1` | `-t 1 --gcthreads=4` | `--gcthreads=4`, `gc_headroom = 1 GiB` |
|---|---|---|---|
| 10k req/s, no garbage: longest pause | 7.4 | 3.4 | 4.6 |
| 10k req/s, 100 KB garbage per request: p99 / p99.9 | 1.46 / 5.5 | 0.28 / 2.6 | 0.14 / 0.33 |
| 10k req/s, 10 KB garbage per request: p99.9 | 0.81 | 0.70 | 0.87 |
| 100 KB garbage per request, max rate: req/s, p99 | 181k, 2.2 | 192k, 1.2 | 211k, 0.62 |
