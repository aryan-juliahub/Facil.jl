# [Performance tuning](@id performance-guide)

This guide lists what changes the speed of a Facil server, most effective
first, and how to measure each. Facil's defaults are chosen to be safe; most
services never need to change them. Come here when you have measured a
problem. Every number is from the [benchmarks](../reference/benchmarks.md)
page, which also says how to reproduce it.

## Measure first

- **Load-test the real handler**, not a hello world, with a tool that reports
  percentiles ([`wrk`](https://github.com/wg/wrk),
  [`oha`](https://github.com/hatoo/oha), `autocannon`). Run the client on
  another machine if you can; on one machine the client competes for cores.
- **Warm up.** The first request to each route compiles it. Discard the first
  seconds of any run.
- **Watch the counters** while it runs. They are cheap enough to expose on a
  metrics endpoint:

  ```@eval
  Main.example("tuning_metrics.jl")
  ```

  [`Facil.paused_requests()`](@ref Facil.paused_requests) that stays high means
  handlers are slower than requests arrive: add threads or make the handler
  faster. [`Facil.pinned_bodies()`](@ref Facil.pinned_bodies) that grows means
  clients are not reading their responses.
- **Measure the handler alone.** A handler is a function; time it and count
  its allocations without a server:

  ```@example perf
  using Facil

  app(req) = Response(StatusCodes.OK, "hello"; headers = [header.CONTENT_TYPE => "text/plain"])

  req = Request(Methods.GET, "/")
  app(req)                       # compile
  @allocated app(req)            # bytes allocated per call
  ```

## 1. Pick the right handler mode

This is the largest lever. [Handlers and concurrency](handlers.md) explains
it in full; in short:

| Your handlers | Use |
|:--|:--|
| wait for I/O, sleep, or take locks | task handlers (the default), `julia -t N` |
| never block, and you want the lowest latency and CPU | `inline = true` |
| compute for more than a fraction of a millisecond | task handlers with one thread per core, or `inline = true` with `reactors = N` |

At a light, steady 10,000 req/s a task-handler server uses about 20% more CPU
than Node.js and has a p99 of 0.17 ms against 0.14 ms (rows 31-cpu and
31-p99), because each request crosses between threads twice. An inline
handler has no crossing.

## 2. Build responses cheaply

A response body is sent without a copy, so the cheapest response is one whose
body already exists:

```@eval
Main.example("perf_precomputed.jl")
```

- **Reuse constant bodies and header lists.** The same `String` can be in
  flight to any number of clients.
- **Never modify a body after returning it.** Facil reads it later, when the
  socket is ready. Build a new `Vector{UInt8}` rather than reusing a buffer.
- **Return `Vector{UInt8}` for data you already have as bytes**; converting to
  a `String` first copies it.
- **JSON serialisation is often the real cost.** Building a 1 KB JSON response
  runs at 69,271 req/s against 237,781 for a prebuilt 150-byte one
  (rows 19a and A2); that time is spent in the JSON library, not in Facil.
  Cache serialised responses that do not change per request.
- **Large static files** go out with [`sendfile`](@ref) or `public_folder`,
  straight from the kernel, without entering Julia. See [Static files](static.md).

## 3. Keep the garbage collector quiet

Every Julia garbage collection stops all threads, the reactor included, so
requests that arrive during a collection wait for it. Short collections are
invisible. Long ones are your p99.9 and your maximum.

### Allocate less per request

Facil allocates the `Request` it hands you: the object, its header map, the
path string and one string per header value, about 500 bytes for a small GET.
The rest is your handler. Two habits keep collections short:

- **Do not keep per-request objects alive** in globals (a "last request"
  slot, an unbounded cache). An object that is still referenced when a
  collection runs is promoted to the old generation, and old garbage is only
  freed by a full collection, which is the slow kind.
- **Avoid large temporaries.** A handler that allocates 100 KB of garbage per
  request collects often; one that allocates 10 KB barely shows (rows 21a and
  21c below).

### Give the collector threads

Julia started with `-t 1` marks and sweeps with a single thread. An inline
server often runs that way, and every pause is then longer than it needs to
be. Collector threads are idle between collections, so they cost nothing:

```sh
julia -t 1 --gcthreads=4 --project=. server.jl
# or
JULIA_NUM_GC_THREADS=4 julia -t 1 --project=. server.jl
```

With `-t 4` or more Julia already uses several. The scoreboard runs every
Facil server with `JULIA_NUM_GC_THREADS=4`.

What to expect, with four collector threads, one reactor, inline handlers and
100 connections (Node.js 22 in brackets):

| Load | Facil | Row |
|:--|:--|:--|
| 10,000 req/s, no garbage: p99.9 | 0.25 ms (0.27) | 22 |
| 10,000 req/s, no garbage: longest single pause | 4.7 ms (4.0) | 32 |
| 10,000 req/s, 10 KB garbage per request: p99.9 | 0.32 ms (0.35) | 21c |
| 10,000 req/s, 100 KB garbage per request: p99 / p99.9 | 0.22 / 2.9 ms (0.14 / 0.16) | 21a |
| 100 KB garbage per request, maximum rate | 195,378 req/s, p99 1.2 ms (133,111, 1.3) | 21b |

Throughput is ahead of Node in every row; the tail under heavy allocation is
not (rows 21a and 32 are approved exceptions on the scoreboard). If your
service has a strict p99.9 target and allocates heavily per request, this is
the limit to know about.

### Heap headroom

Julia sizes its heap from what is live. A server with a small live heap whose
handlers allocate large temporaries collects very often.
[`Facil.gc_headroom!`](@ref) (or the `gc_headroom` keyword of `serve!`) keeps
a block of the given size alive but never written, so the collector behaves as
if the heap were that much larger: fewer collections. It costs address space,
not memory.

```@repl perf
Facil.gc_headroom!(1 << 30) == 1 << 30   # one GiB of headroom
```

It is off by default because it does not help every load. In an earlier run
of rows 21a to 21c (the same machine, before the current scoreboard), 1 GiB of
headroom improved p99.9 from 2.6 ms to 0.33 ms with 100 KB of garbage per
request, and made it slightly worse (0.70 ms to 0.87 ms) with 10 KB. Measure
your own load before keeping it.

### Seeing collections

`GC.enable_logging(true)` prints every pause with its kind (`incr` or `full`).
`Base.gc_num()` has counters for collections, full collections and time;
sample it once a second next to your latency figures to tell a GC pause from
other stalls.

## 4. Uploads

- The default (`Buffer()`) is the fastest way to receive a body that fits in
  memory: 1 MB uploads run at 11,904 req/s against Node's 9,644 (row A12c).
- Reading a streamed body in a task handler (`Stream()` with
  [`body_chunks`](@ref)) pays a thread crossing per chunk: 8,484 requests per
  CPU-second against Node's 11,433 (row 25). When the work per chunk does not
  block (hashing, counting, appending to a buffer), use
  [`Stream`](@ref)`(on_chunk)`, which runs on the reactor without a crossing.

See [Request bodies and uploads](bodies.md).

## 5. Compression

- Compression runs where the handler runs. On a task-handler server it is off
  the event loop: gzip of a 100 KB JSON body at level 6 runs at 12,169 req/s
  (row A11). On an inline server a large body delays every other connection
  while it is compressed.
- `zstd` at its default level is about three times faster than brotli at its
  default for the same body (rows 30a and 30b), and
  [`CompressOptions`](@ref) prefers it when the client accepts it.
- Lower levels are faster; `min_size` skips bodies too small to benefit.
- Precompress what does not change: `public_folder` serves `file.gz` next to
  `file`, and [`Facil.gzip`](@ref) compresses a cached response once.

See [Compression](compression.md).

## 6. Streaming, events and WebSockets

- **Batch writes.** Each `write` to a [`ResponseStream`](@ref) is one chunk on
  the wire. Build a line with `string` and write it once rather than calling
  `print` with several arguments, and `flush` only when the client must see
  the data now.
- **Broadcast with pub/sub.** [`publish`](@ref) to WebSocket clients
  subscribed with [`subscribe`](@ref)`(ws, channel)` builds one frame and
  shares it; a loop of `send` builds one per client and runs Julia code for
  each. 1,000 subscribers at 1,000 messages per second is 968,013 deliveries
  per second (row A14).
- **Keep WebSocket callbacks on the reactor** (`spawn = false`, the default)
  when they do not block: an echo needs no task switch (282,130 messages per
  second, row A29).
- **Bound slow clients** with [`Facil.slow_subscribers!`](@ref) and
  `max_pending_output`, or one stalled client holds memory.

## 7. Connections

- **Keep-alive is on by default** and is the cheap path: a new connection per
  request runs at about 34,000 req/s against 232,517 on kept-alive
  connections (rows 23a and A1). Make sure a proxy in front of Facil reuses
  its upstream connections ([Deployment](deployment.md)).
- **`reactors = N`** helps only when the event loop is the bottleneck: inline
  handlers that compute. It does not speed up tiny replies or task handlers.
- **HTTPS** costs about a third of plaintext throughput for small JSON
  responses (156,251 req/s, row A27, against 237,781, row A2) and is ahead of
  Node's `https`. Handshakes are the expensive part: about 2,300 per second
  for RSA and 7,300 for ECDSA certificates (rows A13a and A13b). Prefer ECDSA
  certificates and keep connections alive.

## 8. Start-up and first request

A Julia process starts in about 0.8 s and the first request to a route waits
about 0.3 s for compilation (rows 12 and 13). Neither affects steady-state
performance. [Deployment](@ref deployment-startup) shows how to warm the
handler at start-up and how to build a system image.

## What not to tune

- **`timeout`, `header_timeout`, `max_pending_output`** are protections, not
  performance settings. Leave them unless you have a reason
  ([Security](security.md)).
- **Thread counts above the number of cores** do not help CPU-bound handlers
  and add scheduling noise.
- **`Base.sleep` in handlers.** It is coarse (about 2.5 ms for a 1 ms sleep
  on macOS). Use [`Facil.sleep`](@ref).

## See also

- [Benchmarks](../reference/benchmarks.md): all 100 scoreboard rows, including
  the ones where Facil is behind
- [Handlers and concurrency](handlers.md), [Deployment](deployment.md)
- [Tuning and diagnostics API](../api/tuning.md)
