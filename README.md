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

Against Node.js v22.23.2 (the fastest Node option per row), on an Apple M5 Pro
(15 cores, macOS), Julia 1.13.0. Loopback, 3 runs per cell, median (min–max),
machine checked idle before each run. Requests per second unless noted.

| Row | Facil | Node | Ratio | Verdict |
|---|---|---|---|---|
| A1 Tiny reply, 1 core | 235,333 (228,443–238,302) | 176,314 (171,378–177,386) | 1.33× | PASS |
| A2 150-byte JSON, 1 core | 210,965 (208,676–218,843) | 155,535 (153,686–157,338) | 1.36× | PASS |
| A3 POST echo | 200,698 (199,246–204,937) | 134,631 (133,451–135,251) | 1.49× | PASS |
| A4 100 KB response | 103,359 (97,588–103,472) | 81,929 (67,047–85,746) | 1.26× | PASS |
| A5 1 MB response | 15,904 (13,307–16,478) | 15,337 (10,459–16,023) | 1.04× | PASS |
| 2 Tiny JSON reply, 4 cores (Node `cluster`) | 165,607 (161,766–175,420) | 149,359 (142,007–167,453) | 1.11× | PASS |
| A12b Upload 64 KB | 100,798 (100,717–100,836) | 70,108 (69,427–70,482) | 1.44× | PASS |
| A27 HTTPS JSON, keep-alive | 144,779 (140,048–146,398) | 128,407 (118,706–128,949) | 1.13× | PASS |
| 17a Handler waits 1 ms (`Facil.sleep`), 100 connections | 85,227 (85,202–85,305) | 58,992 (57,218–59,281) | 1.44× | PASS |
| A14 WebSocket broadcast, 1,000 subscribers × 1,000 Hz (deliveries/s, vs uWebSockets.js) | 1,000,000 (803,213–1,000,000) | 648,340 (559,566–999,800) | 1.54× | PASS |
| A29 WebSocket echo 64 B, 100 connections (msgs/s, vs uWebSockets.js) | 251,333 (246,873–251,963) | 253,778 (253,585–254,145) | 0.99× | FAIL |
| 7-c100 WebSocket echo 256 KB, 100 connections (msgs/s, vs uWebSockets.js) | 27,161 (26,589–27,471) | 27,816 (27,275–28,338) | 0.976× | FAIL |
| 25 1 MB uploads streamed through a task (requests per server CPU-second) | 1,907 (1,869–1,912) | 10,975 (10,531–11,501) | 0.174× | FAIL |
| 31-cpu Task handler at a fixed 10k req/s (server cores used, lower is better) | 2.13 (2.08–2.14) | 0.152 (0.144–0.159) | 0.0714× | FAIL |

Of 60 scoreboard rows measured on both sides, 51 pass and 9 fail; 35 rows
(including memory and start-up time) are not yet measured. The full table, the
failing rows and caveats are in [docs/src/benchmarks.md](docs/src/benchmarks.md);
rows with an approved exception are listed under Known limits below.

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
