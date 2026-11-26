# Facil.jl

An HTTP/1.1 server for Julia built on [facil.io](https://github.com/boazsegev/facil.io).

- **facil.io** (C) does the sockets, the event loop, HTTP/1.1 parsing, static files,
  WebSockets, server-sent events, pub/sub, timers and TLS.
- **HttpTypes** (pure Julia, in `lib/HttpTypes`) supplies the request and response
  types. It is a port of the Rust [`http`](https://github.com/hyperium/http) crate,
  version 1.5.0, with the crate's validation rules and tests. Facil re-exports it.
- Facil is the Julia layer between them: handlers, threads, request bodies,
  streaming, compression.

HTTP.jl is not a dependency.

## Install

Facil is not registered yet, and the prebuilt library (`facil_julia_jll`) is not
published. Until it is, installing needs a C compiler (`clang` or `gcc`) and a local
build of the C library:

```sh
git clone --recurse-submodules <repository URL> Facil.jl
cd Facil.jl
julia --project -e 'using Pkg; Pkg.instantiate()'
julia --project deps/build.jl
```

Julia 1.10 or later on Linux or macOS; CI tests Linux x86_64 and macOS (arm64 and
x86_64). Windows is not supported (facil.io has no Windows port): on Windows, run
Facil inside WSL2. HttpTypes (`lib/HttpTypes`) is pure Julia and works natively on
Windows.

## Hello world

```julia
using Facil

serve("127.0.0.1", 8080) do req
    Response(StatusCodes.OK, "hello")
end
```

```
$ julia -t 4 --project hello.jl &
$ curl http://127.0.0.1:8080/
hello
```

`serve` blocks until the server is closed (Ctrl-C closes it). `serve!` takes the
same arguments and returns a `Server` at once. A handler gets a `Request{String}`
and returns a `Response` (body `String`, `Vector{UInt8}` or `nothing`) or a
`String`. A handler that throws gives a 500.

Every example below was run against the package and checked with `curl` or a
WebSocket client. The [documentation](docs/src/index.md) has one page per topic.

## Routing

There is no router. Branch on `method(req)` and `path(uri(req))`:

```julia
using Facil

function app(req)
    m, p = method(req), path(uri(req))
    if m == Methods.GET && p == "/"
        Response(StatusCodes.OK, "home")
    elseif m == Methods.GET && startswith(p, "/users/")
        id = tryparse(Int, chopprefix(p, "/users/"))
        id === nothing && return Response(StatusCodes.BAD_REQUEST, "bad id")
        Response(StatusCodes.OK, "user $id")
    elseif p == "/" || startswith(p, "/users/")
        Response(StatusCodes.METHOD_NOT_ALLOWED, "only GET"; headers = [header.ALLOW => "GET"])
    else
        Response(StatusCodes.NOT_FOUND, "not found")
    end
end

serve(app, "127.0.0.1", 8080)
```

## JSON

Use any JSON package. Set `content-type` yourself; a `String` body is otherwise
sent as `text/plain; charset=utf-8`.

```julia
using Facil, JSON

const JSON_TYPE = [header.CONTENT_TYPE => "application/json"]

serve("127.0.0.1", 8080) do req
    if method(req) == Methods.POST
        data = JSON.parse(body(req))
        Response(StatusCodes.CREATED, JSON.json(Dict("hello" => data["name"])); headers = JSON_TYPE)
    else
        Response(StatusCodes.OK, JSON.json((status = "ok", path = path(uri(req)))); headers = JSON_TYPE)
    end
end
```

## Query parameters

`query(uri(req))` is the raw query string or `nothing`. Facil does not decode it;
`URIs.queryparams` does:

```julia
using Facil, URIs

serve("127.0.0.1", 8080) do req
    q = queryparams(something(query(uri(req)), ""))
    name = get(q, "name", "world")
    n = something(tryparse(Int, get(q, "n", "1")), 1)
    Response(StatusCodes.OK, join(fill("hello $name", n), "\n"))
end
```

## Request bodies

By default the body is read into memory and `body(req)` is a `String`.
`before_body` is called with the request head when a body starts and chooses per
request: `Buffer()` (default), `Stream()` (read it as it arrives with
`body_chunks(req)` or `body_stream(req)`), `Spool()` (an unlinked temporary file)
or `Reject(status)`.

```julia
using Facil

function choose(head)
    path(uri(head)) == "/upload" && return Stream()
    head.content_length > 1_000_000 && return Reject(413)
    Buffer()
end

serve("127.0.0.1", 8080; before_body = choose) do req
    if path(uri(req)) == "/upload"
        n = 0
        for chunk in body_chunks(req)
            n += length(chunk)
        end
        Response(StatusCodes.OK, "streamed $n bytes")
    else
        Response(StatusCodes.OK, "buffered $(sizeof(body(req))) bytes")
    end
end
```

`max_body_size` (50 MiB) and `body_in_memory` (16 MiB, for `Buffer()`) give 413s.

## Task handlers, inline handlers and threads

By default (`inline = false`) each handler runs on its own Julia task, so it may
block. `inline = true` runs the handler on the reactor thread: cheaper per
request, but a handler that blocks stalls every connection. Task handlers need
Julia started with threads (`julia -t 4`); with one thread, handlers run inline
whatever `inline` says.

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

- `reactors = N` runs the reactor on `N` threads. It is fixed by the first server
  in the process; HTTPS needs `reactors = 1`.
- Task handlers run on worker tasks that wait in C between requests, so idle
  workers use no CPU. Each request is still handed between threads twice, which
  at light load costs more CPU and latency than Node. Handlers that do not block
  should use `inline = true`, and streamed uploads `Stream(on_chunk)`; both beat
  Node.

## `Facil.sleep` and timers

`Base.sleep` is coarse for short waits. `Facil.sleep(seconds)` is timed by a C
timer thread to within tens of microseconds and lets other tasks run; use it in
task handlers (in an inline handler it blocks the reactor). `every(f, ms)` calls
`f()` every `ms` milliseconds until it returns `false`.

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

## Static files

`public_folder` serves a directory (GET, HEAD, OPTIONS) before the handler runs;
`sendfile(path)` sends one file from a handler. Both set `content-type`, `etag`
and `last-modified`, and answer conditional and range requests.

```julia
using Facil

serve("127.0.0.1", 8080; public_folder = "public") do req
    if path(uri(req)) == "/report"
        sendfile("data/report.csv"; headers = [header.CONTENT_DISPOSITION => "attachment"])
    else
        Response(StatusCodes.NOT_FOUND, "no such page")
    end
end
```

## Streaming

`stream(f, req)` returns a response whose body `f(io)` writes while it is sent.
HTTP/1.1 clients get chunked encoding and keep the connection.

```julia
using Facil

serve("127.0.0.1", 8080) do req
    stream(req; headers = [header.CONTENT_TYPE => "text/plain"]) do io
        for i in 1:5
            write(io, "line $i\n")
            flush(io)
            Facil.sleep(0.1)
        end
    end
end
```

## Server-sent events

```julia
using Facil

serve("127.0.0.1", 8080) do req
    path(uri(req)) == "/events" || return Response(StatusCodes.NOT_FOUND, "")
    sse(req) do s
        n = something(tryparse(Int, something(last_event_id(s), "0")), 0)
        for _ in 1:3
            n += 1
            write_event(s; event = "tick", data = "tick $n", id = n)
            Facil.sleep(0.2)
        end
    end
end
```

## Compression

`compress = true` compresses handler results with zstd, brotli or gzip, chosen
from `Accept-Encoding`. Bodies under 1 KiB and non-text types are sent as they are.
`CompressOptions` sets the order, levels and threshold.

```julia
using Facil

const PAGE = repeat("<p>hello</p>\n", 500)

serve("127.0.0.1", 8080; compress = true) do req
    Response(StatusCodes.OK, PAGE; headers = [header.CONTENT_TYPE => "text/html"])
end
```

## WebSockets

```julia
using Facil

serve("127.0.0.1", 8080) do req
    Facil.is_upgrade(req) || return Response(StatusCodes.NOT_FOUND, "WebSocket only")
    websocket(req;
              on_open = ws -> send(ws, "welcome"),
              on_message = (ws, msg) -> send(ws, msg),
              on_close = ws -> @info "closed" ws)
end
```

Callbacks run on the reactor thread, in order, and must not block; `spawn = true`
runs them on tasks. `send(ws, msg)` works from any thread.

## Pub/sub

`subscribe(ws, channel)` forwards a channel to a WebSocket client without running
Julia code per message. `subscribe(f, channel)` calls `f(msg)` in this process.
`publish(channel, msg)` works from any thread.

```julia
using Facil

subscribe(msg -> @info("chat", msg), "chat")

serve("127.0.0.1", 8080) do req
    p = path(uri(req))
    if p == "/chat" && Facil.is_upgrade(req)
        websocket(req;
                  on_open = ws -> subscribe(ws, "chat"),
                  on_message = (ws, msg) -> publish("chat", msg))
    elseif p == "/announce" && method(req) == Methods.POST
        publish("chat", body(req))
        Response(StatusCodes.NO_CONTENT)
    else
        Response(StatusCodes.NOT_FOUND, "")
    end
end
```

## TLS

```julia
using Facil

tls = TLSConfig("cert.pem", "key.pem"; min_version = v"1.2")
server = serve!("127.0.0.1", 8080; tls) do req
    Response(StatusCodes.OK, "secure")
end

reload!(server; cert = "new_cert.pem", key = "new_key.pem")
```

`TLSConfig(cert, key; password, sni, min_version, max_version, ciphers,
ciphersuites, client_ca, require_client_cert)` reads and checks the files when it
is built. `reload!` swaps the certificate for new connections while the server
runs. HTTPS runs on one reactor thread (`reactors = 1`); handlers can still use
many Julia threads.

## Graceful shutdown

`close(server; grace = seconds)` stops accepting, lets requests in progress
finish, and closes what is left after `grace` seconds. For `serve` in the
foreground, SIGTERM does the same with `shutdown_grace` (default 10 s).

```julia
using Facil

server = serve!("127.0.0.1", 8080) do req
    Facil.sleep(1.0)
    Response(StatusCodes.OK, "done")
end

Facil.Timer(_ -> close(server; grace = 5), 0.5)
wait(server)
println(stderr, "server closed")
```

## Benchmarks

Facil against Node.js v22.23.2 on a 100-row scoreboard, each row against the
fastest Node option for that job (`node:http`, `node:https`, `cluster` for
several cores, uWebSockets.js or `ws` for WebSockets). Apple M5 Pro (15 cores,
macOS), Julia 1.13.0, client and server on one machine over loopback, 3 runs per
cell on a machine checked idle before each run. Measured 25 November 2026.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/src/assets/bench-throughput-dark.svg">
  <img alt="Dumbbell chart of requests per second for Facil.jl and Node.js on 23 scoreboard rows. Facil is ahead on 20, from 1.01× to 2.10×; behind on building a 1 KB JSON response (0.53×, approved exception), 256 KB WebSocket echo with 10 connections (0.93×, approved exception) and WebSocket broadcast (0.97×)." src="docs/src/assets/bench-throughput-light.svg" width="830">
</picture>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/src/assets/bench-ratio-dark.svg">
  <img alt="Facil ÷ Node ratio for all 100 scoreboard rows, sorted, log scale: 76 rows at or above 1.0×, 5 failing rows all within 4% of Node, and 19 approved exceptions, the lowest being start-up (0.036×) and first request (0.0065×)." src="docs/src/assets/bench-ratio-light.svg" width="830">
</picture>

**76 pass, 5 fail, 19 approved exceptions.** The five failing rows (A7, A14,
7-c1000, 23b, 29) are each within 4% of Node. The exceptions are Julia start-up,
memory and first-request compile time, JSON building, GC tail latency, task
hand-offs at light load and two macOS WebSocket rows; see Known limits below.

| Row | Facil | Node | Ratio | Verdict |
|---|---|---|---|---|
| A1 Tiny reply, 1 core | 232,517 | 170,961 | 1.36× | PASS |
| A2 150-byte JSON, 1 core | 237,781 | 161,129 | 1.48× | PASS |
| A3 POST echo | 218,288 | 139,026 | 1.57× | PASS |
| A4 100 KB response | 111,611 | 87,291 | 1.28× | PASS |
| A20c Pipelining, depth 16 | 373,962 | 245,715 | 1.52× | PASS |
| A16 Keep-alive, 1,000 connections | 222,037 | 141,560 | 1.57× | PASS |
| 2 Tiny JSON, 4 cores (Node `cluster`) | 185,948 | 179,037 | 1.04× | PASS |
| A27 HTTPS JSON, keep-alive | 156,251 | 130,859 | 1.19× | PASS |
| A12b Upload 64 KB | 112,278 | 72,584 | 1.55× | PASS |
| 27 Streamed gzip, 100 KB JSON | 10,523 | 6,297 | 1.67× | PASS |
| 17a Handler waits 1 ms (`Facil.sleep`), 100 connections | 90,131 | 60,409 | 1.49× | PASS |
| A29 WebSocket echo 64 B, 100 connections (msgs/s, vs uWebSockets.js) | 282,130 | 279,283 | 1.01× | PASS |
| A14 WebSocket broadcast, 1,000 subscribers × 1,000 Hz (deliveries/s, vs uWebSockets.js) | 968,013 | 999,971 | 0.97× | FAIL |
| 19a Build a 1 KB JSON response | 69,271 | 131,376 | 0.53× | EXCEPTION |
| 12 Start-up to first response (ms, lower is better) | 764 | 27.4 | 0.036× | EXCEPTION |
| 10 Memory, idle (MB, lower is better) | 384 | 50.7 | 0.13× | EXCEPTION |

Requests per second (median of 3 runs) unless noted. Numbers come from the full
run of 25 November 2026, with later verification runs replacing rows they
re-measured: rows 19–22 and 32 with `JULIA_NUM_GC_THREADS=4`, and the rows re-run
after the task-pool and WebSocket fixes (A1, A11, A15c, A17, A26, 1–4, 6a–6c, 7*, 8,
17a–18b, 20, 25–27, 31). All 100 rows with min–max ranges are in
[bench/scoreboard/chart_data.csv](bench/scoreboard/chart_data.csv) and
[bench/scoreboard/RESULTS.md](bench/scoreboard/RESULTS.md); method and caveats in
[docs/src/benchmarks.md](docs/src/benchmarks.md). The charts are drawn by
`python3 bench/scoreboard/chart.py`.

Against HTTP.jl 2.16 there is only a measurement from the validation run, with a
prototype Facil server and `autocannon -c 100 -w 4`: empty reply 236,422 against
52,540 req/s (4.50×), 150-byte JSON 230,452 against 51,619 (4.46×).

## Known limits

- HTTP/1.1 only. Linux and macOS only; on Windows use WSL2 (HttpTypes alone runs
  natively on Windows).
- facil.io limits: about 8 KiB per header line and 128 headers (431 above them);
  a `Host` header is required (400 without it).
- facil.io adds `date`, `last-modified` and `connection` when absent; Facil always
  sets `content-length`.
- One reactor per process; stopping a server takes up to about one second.
- A client that disconnects while its handler runs is not noticed.
- Response bodies are sent without a copy and must not be changed afterwards.
- HTTPS runs on one reactor thread.
- Task handlers need more than one Julia thread; with one, handlers run inline.
- A full garbage collection pauses request handling on the reactor (1.2 to 1.7 ms
  in the validation runs).
- Approved exceptions to the "faster than Node on every row" target (2026-11-25):
  start-up, memory and first request (rows 10, 10-sysimg, 11, 12, 12-sysimg,
  12-json, 13, 13-sysimg, 13-json: Julia runtime cost); JSON building (19, 19a:
  Julia's JSON library); task handlers at light load and streamed uploads through
  a task (25, 31-p99, 31-cpu: two cross-thread hand-offs per request or chunk; use
  `inline = true` or `Stream(on_chunk)`, which beat Node); 7-c10 and 26 (macOS
  kernel networking limits, to recheck on Linux); GC tail latency (21a-p99,
  21a-p999, 32, still under target with `JULIA_NUM_GC_THREADS=4`).
- No router, HTTP client, worker processes or Redis engine. HTTP.jl handlers need
  porting (see [docs/src/migrating_from_http_jl.md](docs/src/migrating_from_http_jl.md)).

The full list is in [docs/src/limits.md](docs/src/limits.md).

## Documentation

The `docs/` folder is a Documenter.jl site:

```sh
julia --project=docs -e 'using Pkg; Pkg.instantiate()'
julia --project=docs docs/make.jl
```

It covers each feature, the Rust-to-Julia name table for HttpTypes, migrating from
HTTP.jl, the full benchmark scoreboard and the API reference.

## Licence

- Facil.jl: MIT.
- facil.io: MIT, Copyright (c) 2016-2019 Boaz Segev (`deps/facil.io/LICENSE`).
- HttpTypes.jl: MIT or Apache-2.0, at your option, the same as the Rust `http`
  crate it is ported from (`lib/HttpTypes/LICENSE-MIT`, `lib/HttpTypes/LICENSE-APACHE`).
