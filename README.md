# Facil.jl

[![Docs: dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://aryan-juliahub.github.io/Facil.jl/dev/)
[![CI](https://github.com/aryan-juliahub/Facil.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/aryan-juliahub/Facil.jl/actions/workflows/CI.yml)

An HTTP/1.1 server for Julia built on [facil.io](https://github.com/boazsegev/facil.io).
You write a function from a request to a response; Facil serves it, with
HTTPS, WebSockets, server-sent events, streaming, static files and compression.

```julia
using Facil

serve("127.0.0.1", 8080) do req
    Response(StatusCodes.OK, "hello")
end
```

- **facil.io** (C) does the sockets, the event loop, HTTP/1.1 parsing, static files,
  WebSockets, server-sent events, pub/sub, timers and TLS.
- **HttpTypes** (pure Julia, in `lib/HttpTypes`) supplies the request and response
  types. It is a port of the Rust [`http`](https://github.com/hyperium/http) crate,
  version 1.5.0, with the crate's validation rules and tests. Facil re-exports it.
- Facil is the Julia layer between them: handlers, threads, request bodies,
  streaming, compression.

HTTP.jl is not a dependency.

**Documentation: <https://aryan-juliahub.github.io/Facil.jl/dev/>**

| If you are | Start with |
|---|---|
| new to Facil | [Install](https://aryan-juliahub.github.io/Facil.jl/dev/getting-started/install/), [Your first server](https://aryan-juliahub.github.io/Facil.jl/dev/getting-started/first-server/), [Tutorial: a JSON API](https://aryan-juliahub.github.io/Facil.jl/dev/getting-started/tutorial/) |
| coming from HTTP.jl or Node.js | [Coming from HTTP.jl](https://aryan-juliahub.github.io/Facil.jl/dev/guide/from-http-jl/), [Coming from Node.js](https://aryan-juliahub.github.io/Facil.jl/dev/guide/from-node/) |
| looking something up | [API reference](https://aryan-juliahub.github.io/Facil.jl/dev/api/), [Configuration](https://aryan-juliahub.github.io/Facil.jl/dev/reference/configuration/), [FAQ](https://aryan-juliahub.github.io/Facil.jl/dev/reference/faq/) |

## Install

Facil is not registered yet, and the prebuilt C library (`facil_julia_jll`) is not
published. Until then, installing needs a C compiler (`clang` or `gcc`): the first
`using Facil` downloads the pinned facil.io sources and compiles the library.

From your own project (Julia 1.10 or later):

```sh
julia --project=. -e 'using Pkg; Pkg.add([PackageSpec(url="https://github.com/aryan-juliahub/Facil.jl", subdir="lib/HttpTypes"), PackageSpec(url="https://github.com/aryan-juliahub/Facil.jl")])'
```

On Julia 1.13, `Pkg.add(url="https://github.com/aryan-juliahub/Facil.jl")` alone is enough.

To work on Facil itself, clone it:

```sh
git clone https://github.com/aryan-juliahub/Facil.jl
julia --project=Facil.jl -e 'using Pkg; Pkg.instantiate(); using Facil'
```

Julia 1.10 or later on Linux or macOS; CI tests Linux x86_64 and macOS (arm64 and
x86_64). Windows is not supported (facil.io has no Windows port): on Windows, run
Facil inside WSL2. HttpTypes (`lib/HttpTypes`) is pure Julia and works natively on
Windows. The [install page](https://aryan-juliahub.github.io/Facil.jl/dev/getting-started/install/) covers what can go wrong.

## Quick start

Save the five lines at the top of this page as `hello.jl` and run them with
more than one Julia thread:

```
$ julia -t 4 --project=. hello.jl &
$ curl http://127.0.0.1:8080/
hello
```

`serve` blocks until the server is stopped. `serve!` takes the same arguments
and returns a `Server` at once (`close(server)` stops it; port `0` picks a free
port, which is what tests want). A handler gets a `Request{String}` and returns
a `Response` (body `String`, `Vector{UInt8}` or `nothing`) or a `String`. A
handler that throws gives a 500.

By default a handler runs on a task of Facil's worker pool, on Julia's threads,
so it may block. `inline = true` runs handlers on the event-loop thread instead:
faster, but a handler that blocks then stalls every connection. With one Julia
thread, handlers always run inline. See
[Handlers and concurrency](https://aryan-juliahub.github.io/Facil.jl/dev/guide/handlers/).

There is no router; a handler branches on the method and the path:

```julia
using Facil

function app(req)
    m, p = method(req), path(uri(req))
    if p == "/"
        m == Methods.GET || return not_allowed("GET")
        Response(StatusCodes.OK, "home\n")
    elseif startswith(p, "/users/")
        m == Methods.GET || return not_allowed("GET")
        id = tryparse(Int, chopprefix(p, "/users/"))
        id === nothing && return Response(StatusCodes.BAD_REQUEST, "bad id\n")
        Response(StatusCodes.OK, "user $id\n")
    else
        Response(StatusCodes.NOT_FOUND, "not found\n")
    end
end

not_allowed(allow) = Response(StatusCodes.METHOD_NOT_ALLOWED, "method not allowed\n"; headers = [header.ALLOW => allow])

serve(app, "127.0.0.1", 8080)
```

WebSockets are accepted from the same handler:

```julia
using Facil

serve("127.0.0.1", 8080) do req
    Facil.is_upgrade(req) || return Response(StatusCodes.UPGRADE_REQUIRED, "WebSocket only";
                                             headers = [header.UPGRADE => "websocket"])
    websocket(req;
              on_open = ws -> send(ws, "welcome"),
              on_message = (ws, msg) -> send(ws, msg),
              on_close = ws -> println("client gone"))
end
```

Every code block in this README is a file in [`docs/examples`](docs/examples),
which the documentation build and the test suite start on a free port and check
with a client.

## What is in the box

| Feature | Guide |
|---|---|
| Task and inline handlers, reactor threads | [Handlers and concurrency](https://aryan-juliahub.github.io/Facil.jl/dev/guide/handlers/) |
| Reading requests; query strings; limits | [Reading requests](https://aryan-juliahub.github.io/Facil.jl/dev/guide/requests/) |
| Uploads: buffered, streamed, spooled to disk, rejected early | [Request bodies](https://aryan-juliahub.github.io/Facil.jl/dev/guide/bodies/) |
| Responses, redirects, headers | [Sending responses](https://aryan-juliahub.github.io/Facil.jl/dev/guide/responses/) |
| Routing without a framework; JSON | [Routing](https://aryan-juliahub.github.io/Facil.jl/dev/guide/routing/), [JSON](https://aryan-juliahub.github.io/Facil.jl/dev/guide/json/) |
| Chunked streaming and server-sent events | [Streaming](https://aryan-juliahub.github.io/Facil.jl/dev/guide/streaming/), [SSE](https://aryan-juliahub.github.io/Facil.jl/dev/guide/sse/) |
| Static files with ETag, ranges and `.gz` siblings | [Static files](https://aryan-juliahub.github.io/Facil.jl/dev/guide/static/) |
| zstd, brotli and gzip compression | [Compression](https://aryan-juliahub.github.io/Facil.jl/dev/guide/compression/) |
| WebSockets and process-local pub/sub | [WebSockets](https://aryan-juliahub.github.io/Facil.jl/dev/guide/websockets/), [Pub/sub](https://aryan-juliahub.github.io/Facil.jl/dev/guide/pubsub/) |
| HTTPS with SNI, client certificates, live certificate reload | [HTTPS](https://aryan-juliahub.github.io/Facil.jl/dev/guide/tls/) |
| Accurate timers and `Facil.sleep` | [Timers](https://aryan-juliahub.github.io/Facil.jl/dev/guide/timers/) |
| Graceful shutdown on SIGTERM | [Shutdown and signals](https://aryan-juliahub.github.io/Facil.jl/dev/guide/shutdown/) |
| Errors, logging, testing | [Errors](https://aryan-juliahub.github.io/Facil.jl/dev/guide/errors/), [Testing](https://aryan-juliahub.github.io/Facil.jl/dev/guide/testing/) |
| systemd, containers, reverse proxies, system images | [Deployment](https://aryan-juliahub.github.io/Facil.jl/dev/guide/deployment/) |
| Tuning and security | [Performance](https://aryan-juliahub.github.io/Facil.jl/dev/guide/performance/), [Security](https://aryan-juliahub.github.io/Facil.jl/dev/guide/security/) |

## Benchmarks

Facil against Node.js v22.23.2 on a 100-row scoreboard, each row against the
fastest Node option for that job (`node:http`, `node:https`, `cluster` for
several cores, uWebSockets.js or `ws` for WebSockets). Apple M5 Pro (15 cores,
macOS), Julia 1.13.0, client and server on one machine over loopback, 3 runs per
cell on a machine checked idle before each run, Facil servers with
`JULIA_NUM_GC_THREADS=4`. Measured 26 November 2026.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/src/assets/bench-throughput-dark.svg">
  <img alt="Dumbbell chart of requests per second for Facil.jl and Node.js on 23 scoreboard rows. Facil is ahead on 20, from 1.01× to 1.77×; behind on building a 1 KB JSON response (0.53×, approved exception), 256 KB WebSocket echo with 10 connections (0.98×, approved exception) and with 100 connections (0.997×)." src="docs/src/assets/bench-throughput-light.svg" width="830">
</picture>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/src/assets/bench-ratio-dark.svg">
  <img alt="Facil ÷ Node ratio for all 100 scoreboard rows, sorted, log scale: 72 rows at or above 1.0×, 9 failing rows (5 within 5% of Node, the worst 0.59×), and 19 approved exceptions, the lowest being start-up (0.033×) and first request (0.0068×)." src="docs/src/assets/bench-ratio-light.svg" width="830">
</picture>

**72 pass, 9 fail, 19 approved exceptions.** Five failing rows are within 5% of
Node (A7, A15c, A19d, 7-c100, 23a). Four are not: 7-c1000 (256 KB WebSocket
echo, 1,000 connections, 0.93×) and three latency tails at a light, fixed load
(21b-p99 0.71×, 21c 0.59×, 22 0.87×), where Julia's GC pauses show. The
exceptions are Julia start-up, memory and first-request compile time, JSON
building, GC tail latency, task hand-offs and two macOS WebSocket rows; see
Known limits below.

| Row | Facil | Node | Ratio | Verdict |
|---|---|---|---|---|
| A1 Tiny reply, 1 core | 248,626 | 179,610 | 1.38× | PASS |
| A2 150-byte JSON, 1 core | 231,505 | 158,620 | 1.46× | PASS |
| A3 POST echo | 214,696 | 136,737 | 1.57× | PASS |
| A4 100 KB response | 108,805 | 85,383 | 1.27× | PASS |
| A20c Pipelining, depth 16 | 374,122 | 241,882 | 1.55× | PASS |
| A16 Keep-alive, 1,000 connections | 212,510 | 135,408 | 1.57× | PASS |
| 2 Tiny JSON, 4 cores (Node `cluster`) | 186,603 | 179,389 | 1.04× | PASS |
| A27 HTTPS JSON, keep-alive | 156,651 | 128,953 | 1.21× | PASS |
| A12b Upload 64 KB | 98,315 | 67,957 | 1.45× | PASS |
| 27 Streamed gzip, 100 KB JSON | 11,257 | 6,348 | 1.77× | PASS |
| 17a Handler waits 1 ms (`Facil.sleep`), 100 connections | 85,941 | 55,382 | 1.55× | PASS |
| A29 WebSocket echo 64 B, 100 connections (msgs/s, vs uWebSockets.js) | 281,369 | 276,838 | 1.02× | PASS |
| A19d 100 request headers | 31,167 | 31,900 | 0.98× | FAIL |
| 21c p99.9 at 10k req/s, 10 KB garbage per request (ms, lower is better) | 0.274 | 0.161 | 0.59× | FAIL |
| 19a Build a 1 KB JSON response | 67,053 | 127,284 | 0.53× | EXCEPTION |
| 25 1 MB upload streamed through a task (requests per CPU-second) | 2,431 | 11,585 | 0.21× | EXCEPTION |
| 12 Start-up to first response (ms, lower is better) | 881 | 29.3 | 0.033× | EXCEPTION |
| 10 Memory, idle (MB, lower is better) | 387 | 51.0 | 0.13× | EXCEPTION |

Requests per second (median of 3 runs) unless noted. Numbers come from the full
run of 26 November 2026, with a rerun (both sides, 3 runs) replacing every row
whose verdict differed from the previous published numbers, plus A17, 25, 32
and the start-up rows. Row 25 fell from 0.74× to 0.21× since 25 November: the
server now spends about 3.5 times the CPU per upload; the cause is not yet
traced.

On Apple silicon Julia 1.12 and 1.13 can crash in GC marking with more than one
GC thread, so the [deployment guide](docs/src/guide/deployment.md) recommends
`JULIA_NUM_GC_THREADS=1` there. With one GC thread throughput barely changes
(21b 184,515 against 195,114 req/s) but allocation-heavy tails grow: 21a p99
2.15 ms against 0.23 ms, the longest pause (32) 11.6 ms against 2.6 ms. No
verdict changes.

All 100 rows with min–max ranges are in
[bench/scoreboard/chart_data.csv](bench/scoreboard/chart_data.csv) and
[bench/scoreboard/RESULTS.md](bench/scoreboard/RESULTS.md) (with what changed
since 25 November and the one-GC-thread table); method and caveats in
[docs/src/reference/benchmarks.md](docs/src/reference/benchmarks.md). The charts are drawn by
`python3 bench/scoreboard/chart.py`.

Against HTTP.jl 2.16 there is only a measurement from the validation run, with a
prototype Facil server and `autocannon -c 100 -w 4`: empty reply 236,422 against
52,540 req/s (4.50×), 150-byte JSON 230,452 against 51,619 (4.46×).

## Known limits

- HTTP/1.1 only. Linux and macOS only; on Windows use WSL2 (HttpTypes alone runs
  natively on Windows).
- Not registered yet; installing is `Pkg.add` by URL and needs a C compiler.
- No router, HTTP client, worker processes or Redis engine. HTTP.jl handlers need
  porting to HttpTypes.
- facil.io limits: about 8 KiB per header line and 128 headers (431 above them);
  a `Host` header is required (400 without it).
- On Julia 1.10 and 1.11 the SIGTERM drain cannot finish handlers that wait on
  I/O; Julia 1.12 and later drain every handler.
- facil.io adds `date`, `last-modified` and `connection` when absent; Facil always
  sets `content-length`.
- A client that disconnects while its handler runs is not noticed, and there is
  no way to read a client's address.
- Response bodies are sent without a copy and must not be changed afterwards.
- One reactor per process; HTTPS runs on one reactor thread.
- Task handlers need more than one Julia thread; with one, handlers run inline.
- A garbage collection pauses request handling, the reactor included.
- Ctrl-C stops `serve` cleanly only at the REPL; use SIGTERM for a running
  script.
- Approved exceptions to the "faster than Node on every row" target (2026-11-25):
  start-up, memory and first request (Julia runtime cost); JSON building (Julia's
  JSON library); task handlers at light load and streamed uploads through a task
  (use `inline = true` or `Stream(on_chunk)`, which beat Node); two WebSocket
  rows on macOS; GC tail latency.

The full list, with what happens at each limit, is on the
[Limits](https://aryan-juliahub.github.io/Facil.jl/dev/reference/limits/) page.

## Documentation

The site at <https://aryan-juliahub.github.io/Facil.jl/dev/> is built from `docs/` with Documenter.jl on every push to
`main`. To build it locally:

```sh
julia --project=docs -e 'using Pkg; Pkg.instantiate()'
julia -t 4 --project=docs docs/make.jl
```

The build runs every example program in `docs/examples` against a client, runs
the doctests in the docstrings, and fails on any warning.

Contributors and coding agents: start with [AGENTS.md](AGENTS.md).

## Licence

- Facil.jl: MIT.
- facil.io: MIT, Copyright (c) 2016-2019 Boaz Segev (text in `THIRD_PARTY_NOTICES.md`).
- HttpTypes.jl: MIT or Apache-2.0, at your option, the same as the Rust `http`
  crate it is ported from (`lib/HttpTypes/LICENSE-MIT`, `lib/HttpTypes/LICENSE-APACHE`).
