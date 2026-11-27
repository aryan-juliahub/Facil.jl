# [Limits](@id limits-reference)

This page states plainly what Facil does not do, where its limits are and
what happens at each one. Read it before you commit to Facil for a project;
nothing here is hidden elsewhere.

## Protocol and platform

- **HTTP/1.1 and HTTP/1.0 only.** No HTTP/2, no HTTP/3. Put a reverse proxy
  in front if browsers must reach you over HTTP/2
  ([Deployment](../guide/deployment.md)).
- **Linux and macOS only.** On Windows, run Facil inside WSL2. See
  [Platform support](platforms.md).
- **A C compiler is needed to install**, until the prebuilt library is
  published, and the package is not in the General registry yet
  ([Install](../getting-started/install.md)).

## Request limits

| Limit | Default | Over the limit | Connection |
|:--|:--|:--|:--|
| Whole request head | `max_header_size = 32 KiB` | `431` | closed |
| One header line | about 8 KiB (facil.io) | `431` | closed |
| Number of headers | 128 (facil.io) | `431` | closed |
| Request body | `max_body_size = 50 MiB` | `413` | closed |
| Body held in memory by `Buffer()` | `body_in_memory = 16 MiB` | `413` | closed |
| Time to send the request head | `header_timeout = 30 s` | `408` | closed |
| Idle connection | `timeout = 40 s` | closed silently | closed |
| `Host` header | required, for HTTP/1.0 too | `400` | kept |
| Request target or header name that HttpTypes rejects | | `400` | kept |
| Distinct header names in a `HeaderMap` | 24,576 | [`MaxSizeReached`](@ref) | |

The keyword limits are per server; see [Configuration](configuration.md).

- The `408` is sent to a client that is still trickling its request head when
  `header_timeout` expires. A client that sends part of a head and then
  nothing is closed without a response when the idle `timeout` expires.
- **`path(uri(req))` and `query(uri(req))` are what the client sent**: not
  percent-decoded, not split, not normalised. [`decoded_path`](@ref) and
  [`query_param`](@ref) decode them; `decoded_path` returns `nothing` for an
  encoded `/` or NUL, a bad escape or invalid UTF-8, and does not resolve
  `..` ([Query strings and forms](../guide/urls-and-forms.md)).
- A request line must be `method SP target SP version`: one with a further
  space (`GET /a b HTTP/1.1`) gets a `400`.

## Response behaviour to know about

- **Every status from 100 to 999 is sent as given**, with HttpTypes'
  `canonical_reason` as the reason phrase, or `Unknown` for a code that has
  none (`299`, `599`).
- **`1xx`, `204` and `304` responses are sent without a body** and without
  `content-length` or a default `content-type`, even when the `Response` has
  a body. Other headers are sent as set.
- **`date` and `connection` are added** to every response that does not set
  them, streamed ones and event streams included. **`last-modified` is added**
  to every non-streamed one: it is the time of the response, which tells
  caches the content just changed; set your own `last-modified` or
  `cache-control` on anything you want cached.
- **`content-length` and `transfer-encoding` are set by Facil.** Values you
  set are ignored.
- **A `204` or `304` response keeps a body if you give it one.** Do not give
  it one.
- **Response bodies are sent without a copy.** Do not change a `Vector{UInt8}`
  after returning it from a handler or writing it to a stream.
- **Each `write` to a streamed response is one chunk on the wire.**
- A streamed response to an HTTP/1.0 client ends by closing the connection.
  After an event stream ([`sse`](@ref)) the connection is closed.

## Handlers, threads and the reactor

- **One reactor per process**, shared by every server. `reactors` is fixed by
  the first server started.
- **Task handlers need more than one Julia thread.** With `julia -t 1` every
  handler runs inline on the reactor thread, whatever `inline` says.
- **Anything that runs on the reactor thread must not block**: inline
  handlers, `before_body`, `Stream(on_chunk)`, WebSocket callbacks without
  `spawn = true`, `subscribe(f, channel)` callbacks without `spawn = true`.
  One that blocks stalls every connection on that thread.
- **HTTPS needs `reactors = 1`.**
- **No cancellation.** A handler whose client goes away runs to the end and
  its result is discarded, unless it checks for itself:
  - A task handler can ask [`isconnected`](@ref) or register
    [`on_disconnect`](@ref). The connection is checked every 200 ms once
    something watches it, so a close is seen within about half a second.
  - An **inline handler gets no detection**: `isconnected` is always `true`
    and `on_disconnect` does nothing, because the reactor running the handler
    cannot watch the connection meanwhile.
  - TCP does not tell a client that closed from one that only shut down its
    write side (a half-close) and still waits for the answer. For an HTTP/1.1
    request Facil sends one `100 Continue` interim response to find out: a
    closed client answers it with a reset. **HTTP/1.0 and upgrade requests**
    cannot be sent one, so for them only a reset or a server-side close
    counts as gone; a client that sent its FIN is treated as still there.
  - Streamed responses and event streams notice through `isopen`. See
    [A client that goes away](../guide/handlers.md#A-client-that-goes-away).
- **Garbage collection pauses request handling.** A collection stops every
  thread, the reactor included. See
  [Performance tuning](../guide/performance.md) for sizes and remedies.
- **On Julia 1.10 and 1.11 the SIGTERM drain does not finish handlers that
  are waiting on I/O.** There Julia's event loop no longer runs after the
  signal, so a handler waiting on a socket, a process or `Base.sleep` is lost
  after the grace period, and on 1.10 other handlers are not reliable
  either. Call `close(server; grace)` before stopping the process. Julia 1.12
  and later drain every handler. See
  [Shutdown and signals](@ref shutdown-drain-io).
- **Ctrl-C stops `serve` cleanly only at the REPL.** In a script Julia prints
  its interrupt report first; under `julia -e`, or with
  `Base.exit_on_sigint(false)`, Ctrl-C does not stop the server at all. Use
  SIGTERM. See [Shutdown and signals](../guide/shutdown.md).

## Static files

Behaviour of `public_folder` and [`sendfile`](@ref):

- `cache-control: max-age=3600` by default. `static_cache_control` changes
  it (or drops it) for `public_folder` files; a file from `sendfile` always
  gets `max-age=3600`.
- `If-None-Match` and `If-Modified-Since` are honoured; when both are sent,
  `If-None-Match` decides.
- One byte range is served (`206`); a request for several ranges gets the
  whole file (`200`).
- `public_folder`: a directory with an `index.html`, asked for without its
  trailing slash, gets a `301` to the path with the slash.
- `public_folder`: paths with a part that starts with a dot are not served
  by default (`dotfiles = :deny`), except under `/.well-known`. Symbolic
  links are followed by default, including links that point outside the folder
  (`symlinks = :inside` stops that).
- The `etag` is derived from size and modification time, not the content.

See [Static files](../guide/static.md).

## Not included

- **No router**, no middleware framework, no templates, no sessions or cookie
  signing, no multipart parser, no CORS helper. Handlers are plain
  functions; the guides show how to write each of these in a few lines where
  it is short ([Routing](../guide/routing.md), [Security](../guide/security.md)).
  Cookies and URL-encoded forms do have helpers ([Cookies](../guide/cookies.md),
  [Query strings and forms](../guide/urls-and-forms.md)).
- **No HTTP client.** Use `Downloads` (bundled with Julia) or HTTP.jl as a
  client.
- **No worker processes** (`fork`, `cluster`). Scale with threads.
- **Pub/sub is local to the process.** facil.io's Redis engine is not wrapped.
- **Existing HTTP.jl handlers and routers do not plug in.** They need porting
  to HttpTypes; see [Coming from HTTP.jl](../guide/from-http-jl.md).

## Where Facil is slower than Node.js

The project's target is at least 1.0× Node.js on every row of the
[scoreboard](benchmarks.md). These rows are under it and are approved
exceptions (2026-11-25):

| Rows | What | Why |
|:--|:--|:--|
| 10, 10-sysimg, 11 | Memory, idle and with 10,000 connections | The Julia runtime: about 390 MB idle against Node's 50 MB |
| 12, 12-sysimg, 12-json, 13, 13-sysimg, 13-json | Start-up and first request | Julia start-up and compilation: 0.70 s to first response, 0.31 s for a first request |
| 19, 19a | Building a 50 KB or 1 KB JSON response | The JSON library's serialisation, not the server |
| 25 | 1 MB upload streamed through a task | Julia's idle worker threads spin (100 µs each) between chunk hand-offs and use the CPU. `JULIA_THREAD_SLEEP_THRESHOLD=0` at launch gives 0.71×; `Stream(on_chunk)` avoids the hand-offs |
| 31-p99, 31-cpu | Task handler at a light 10,000 req/s | Two thread crossings per request; `inline = true` avoids them |
| 7-c10 | WebSocket echo of 256 KB messages, 10 connections | macOS kernel networking; to be rechecked on Linux |
| 26 | WebSocket broadcast to 10,000 subscribers | macOS socket memory; to be rechecked on Linux |
| 21a-p99, 21a-p999, 32 | Tail latency and longest pause at 10,000 req/s | Julia GC pauses |

Nine more rows fail: five within 5% of Node, 256 KB WebSocket echo with 1,000
connections (0.93×), and three latency tails at a light or allocation-heavy load
(0.59× to 0.87×). They are listed on the [benchmarks](benchmarks.md#Failing-rows) page. All numbers were measured
on macOS; the scoreboard has not been run on Linux.
