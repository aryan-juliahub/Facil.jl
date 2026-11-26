# Known limits

## Platform

- HTTP/1.1 only. No HTTP/2 or HTTP/3.
- Linux and macOS only; CI tests Linux x86_64 and macOS (arm64 and x86_64) on
  Julia 1.10 and the latest release. Windows is not supported because facil.io
  has no Windows port: run Facil inside WSL2. Loading or building Facil on
  Windows stops with an error saying so.
- HttpTypes is pure Julia and works natively on Windows (tested in CI).
- Until `facil_julia_jll` is published, installing needs a C compiler.

## Requests

| Limit | Default | Over the limit |
|---|---|---|
| One header line | about 8 KiB (facil.io) | 431 |
| Number of headers | 128 (facil.io) | 431 |
| Whole request head | `max_header_size = 32 KiB` | 431 |
| Request body | `max_body_size = 50 MiB` | 413 |
| Body held in memory (`Buffer()`) | `body_in_memory = 16 MiB` | 413 |
| Time to send the request head | `header_timeout = 30` s | 408 |
| `Host` header | required, also for HTTP/1.0 | 400 |

- Query strings are not split or percent-decoded; paths are not percent-decoded.
- A request that facil.io parsed but HttpTypes rejects (bad target or header name)
  gets a 400.

## Responses

- facil.io adds `date`, `last-modified` and `connection` when they are absent,
  and Facil always sets `content-length` (or chunked framing) itself.
- Response bodies are sent without a copy. Do not change a `Vector{UInt8}` after
  returning it from a handler or writing it to a stream.
- A streamed response to an HTTP/1.0 client ends by closing the connection. After
  an SSE response the connection is closed when the event function returns.

## Threads and the reactor

- One reactor per process. `reactors` is fixed by the first server; every
  server shares it. Stopping a server takes up to about one second.
- Task handlers (`inline = false`) need Julia started with more than one thread;
  with one thread, handlers run inline on the reactor.
- An inline handler, WebSocket callback (without `spawn = true`) or
  `subscribe(f, channel)` callback that blocks stalls every connection on its
  reactor thread.
- HTTPS needs `reactors = 1`.
- A client that disconnects while its handler runs is not noticed; the handler
  finishes and its response is discarded. There is no cancellation.
- A full garbage collection pauses request handling on the reactor (1.2 to 1.7 ms
  in the validation runs). Allocation-heavy handlers see this in tail latency.

## Not included

- No router, no HTTP client, no cookie or session helpers, no templates.
- No worker processes (`fork`); use reactor threads and Julia threads instead.
- Pub/sub is process-local; facil.io's Redis engine is not wrapped.
- Existing HTTP.jl handlers need porting to HttpTypes; see
  [Migrating from HTTP.jl](migrating_from_http_jl.md).

## Performance gaps

The release target is at least 1.0× Node.js on every scoreboard row (see
[Benchmarks](benchmarks.md)). These rows are approved exceptions (2026-11-25);
the scoreboard marks them EXCEPTION instead of FAIL when they are under target:

| Rows | What | Reason |
|---|---|---|
| 10, 10-sysimg, 11 | Memory, idle and with 10,000 connections | Julia runtime start-up and memory cost |
| 12, 12-sysimg, 12-json, 13, 13-sysimg, 13-json | Start-up to first response, first request | Julia runtime start-up and first-request (compilation) cost |
| 19, 19a | Build a 50 KB / 1 KB JSON response | Cost of Julia's JSON library serialising the body, not of the server |
| 25 | 1 MB upload streamed through a task, per CPU-second | Task handlers pay two cross-thread hand-offs per chunk; `Stream(on_chunk)` beats Node |
| 31-p99, 31-cpu | Task handler at a light 10k req/s: p99, CPU | Two cross-thread hand-offs per request; `inline = true` beats Node |
| 7-c10 | WebSocket echo 256 KB, 10 connections | macOS kernel networking limit (bound by `writev`); recheck on Linux |
| 26 | WebSocket broadcast to 10,000 subscribers | macOS socket-memory exhaustion and retransmits; recheck on Linux |
| 21a-p99, 21a-p999, 32 | Tail latency and longest pause at 10k req/s | Julia GC pauses; still under target with `JULIA_NUM_GC_THREADS=4` |

For light-load handlers that do not block, use `inline = true`; for streamed
uploads, use `Stream(on_chunk)` (see [Threads](guide/threads.md#Idle-CPU) and
[Request bodies](guide/bodies.md)).
