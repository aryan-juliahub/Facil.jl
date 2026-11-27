# Changelog

## Unreleased

First version. Nothing has been released or registered yet.

> **Behaviour change:** `public_folder` no longer serves dotfiles by default.
> `dotfiles = :deny` is now the default: a path with a part that starts with
> a dot (`/.env`, `/.git/config`) reaches the handler as if the file did not
> exist, except under `/.well-known`. Pass `dotfiles = :serve` for the
> earlier behaviour.

### Server

- `serve` (blocking) and `serve!` (returns a `Server`), with `close`, `wait`,
  `isopen` and `port`. Port 0 picks a free port.
- Handlers take an HttpTypes `Request{String}` and return a `Response` or a
  `String`. A handler that throws gives a 500; errors are logged once per type
  every 10 seconds. Requests HttpTypes rejects get a 400.
- Task handlers by default (`inline = false`), inline handlers on the reactor
  thread with `inline = true`; handlers run inline when Julia has one thread.
- `reactors = N` reactor threads, shared by every server in the process.
- Response bodies are sent without a copy (headers and body in one `writev`).
- HEAD is answered with headers only.
- Limits: `max_header_size`, `max_body_size`, `body_in_memory`, `timeout`,
  `header_timeout` (408), `max_pending_output` (slow readers are disconnected).
- Request bodies chosen per request with `before_body`: `Buffer`, `Stream`
  (with `body_chunks`, `body_stream` or an `on_chunk` callback), `Spool`,
  `Reject`.
- Graceful shutdown with `close(server; grace)`; SIGTERM drains servers run with
  `serve` (`shutdown_grace`).
- `Facil.sleep` and `Facil.Timer` / `every`, timed by a C timer thread.
- Streaming responses with `stream` (chunked on HTTP/1.1, keep-alive kept).
- Server-sent events with `sse`, `write_event`, `last_event_id`.
- Streamed responses and event streams carry a `date` header, like the others.
- Compression with `compress = true` or `CompressOptions`: zstd, brotli and gzip
  (libdeflate, zlib-ng for long streams), also for streamed responses.
- WebSockets with `websocket`: callbacks on the reactor or on tasks, `send` from
  any thread, close codes, message size limit, UTF-8 check, permessage-deflate,
  subprotocols.
- Pub/sub with `subscribe`, `unsubscribe` and `publish`; WebSocket subscribers
  receive shared frames without Julia code per message; slow-subscriber policies.
- HTTPS with `TLSConfig` (chains, encrypted keys, SNI, protocol range, ciphers,
  client certificates) and `reload!` for certificate rotation.
- Callbacks precompiled with PrecompileTools.

#### Requests: queries, forms, cookies, the client

- Query strings, paths and forms: `query_param`, `query_params`,
  `decoded_path` (returns `nothing` for `%2F`, `%00`, bad escapes or invalid
  UTF-8), `parse_form`, `parse_query`, `percent_decode` and `percent_encode`.
  WHATWG `URLSearchParams` rules; the names do not clash with URIs.jl's.
- Cookies: `cookies(req)` (RFC 6265 lenient parsing, first value wins),
  `set_cookie!` with `Path`, `Domain`, `Max-Age`, `Expires`, `Secure`,
  `HttpOnly`, `SameSite`, `Partitioned`, and `delete_cookie!`. Invalid names,
  values and attribute combinations throw an `ArgumentError`.
- The client of a request: `client_address(req)` gives `(ip, port)` (IPv4 and
  IPv6, HTTP and HTTPS, captured when the request arrives) and
  `client_certificate(req)` the PEM certificate of a mutual-TLS client.
- A task handler can learn that its client left: `isconnected(req)` and
  `on_disconnect(f, req)`, within about half a second (the connection is
  checked every 200 ms while watched). A half-close is told apart from a close
  with one `100 Continue` interim response on HTTP/1.1; for HTTP/1.0 and
  upgrade requests only a reset counts. Inline handlers get no detection.

#### Static files

- `public_folder` and `sendfile`: ETag, `Last-Modified`, conditional and
  single-range requests, precompressed `.gz` files, `Facil.register_mime!`.
- `If-Modified-Since` is honoured (`If-None-Match` wins when both are sent).
- `static_cache_control` sets (or with `nothing` drops) the `cache-control`
  of `public_folder` files; the default stays `max-age=3600`.
- A directory asked for without its trailing slash gets a `301` to the path
  with the slash when it has an `index.html`, query kept.
- `dotfiles = :serve | :deny` (default `:deny`, `.well-known` always served;
  see the behaviour change above) and `symlinks = :follow | :inside` (default
  `:follow`).

#### Performance

- Task-handler worker pool fixes: a steady stream of newly spawned tasks can no
  longer starve older ones (Julia's run queue is not first-in first-out), and a
  runner yields its thread when other tasks wait for one. Streamed gzip (row 27)
  went from 2.8k to 10.3k req/s.
- Streamed request-body chunks come from a pool of reused buffers instead of a
  new array per chunk.
- Removed the idle-thread spin override: Facil no longer reads Julia's symbol
  table or changes Julia runtime variables. For light-load handlers use
  `inline = true`, and for streamed uploads `Stream(on_chunk)`; or start Julia
  with `JULIA_THREAD_SLEEP_THRESHOLD=0` (row 25: 2.5k to 8.8k requests per
  CPU-second).
- `serve!` hands its keywords to code compiled in the package image, so a
  script's first `serve!` call compiles about 60 ms instead of 230 ms
  (start-up row 12: 868 to 701 ms).

#### Fixes

- Fixes and behaviour changes after the first documentation pass:
  - Every status from 100 to 999 is sent with its own number. Before, `418`,
    `451` and every code without a registered phrase went out as `500`. The
    phrase is `canonical_reason(status)`, or `Unknown`.
  - `1xx`, `204` and `304` responses are sent without a body, without
    `content-length` and without a default `content-type`; before, a body
    given with them was sent.
  - A request line with a space inside the target (`GET /a b HTTP/1.1`) gets a
    `400`; before, the handler saw the target up to the space.
  - `public_folder`: a path with an encoded NUL (`%00`) gets a `400`; before,
    the NUL cut the file name short (`/a.txt%00.png` served `a.txt`).
  - An unknown `serve` or `serve!` keyword throws an `ArgumentError` that names
    the closest valid keyword; before, a `MethodError` about
    `Facil.ServerOptions`.
  - `close(server)` and `close(server; grace)` call `on_shutdown` for the
    server's WebSockets and send them a `1001` close; before, they were
    dropped without a close frame. With `grace` this happens when the drain
    starts.
  - SIGTERM (and Ctrl-C in a script) under `serve`: on Julia 1.12 and later
    handlers waiting on I/O (`Base.sleep`, sockets, child processes) finish
    within `shutdown_grace`; before, they never returned. The first `serve`
    now moves Julia's event loop to its own thread
    (`Base.Experimental.make_io_thread`), every server of the process is
    drained with its own `shutdown_grace`, and the verbose log has one more
    line per server. Julia 1.10 and 1.11 keep the old limits, but the process
    no longer hangs at exit when a handler is stuck.
  - The error log limit is per error type and call site (innermost four
    frames), no longer per type alone.
  - `Facil.Timer` has a `show` method.
- A client that writes its request and closes, or shuts down its write side,
  at once is read and answered. Before, the connection was closed unread
  whenever the client's FIN was already there at the first poll: the handler
  did not run and no response was sent (3 of 200 such requests were handled
  on macOS and on x86-64 Linux). Now every request that arrived is handled,
  pipelined ones included; a client that only shut down its write side gets
  the responses and then the connection is closed; for one that closed
  completely the handler still runs and the response is dropped. The same
  holds over TLS, and for WebSocket frames sent just before a close.
- aarch64 Linux is tested in CI. There the brotli decoder of `brotli_jll`
  (every version from 1.0.9 to 1.2.1) rejects valid streams, also from a C
  program, while its encoder's output is byte-identical to other platforms.
  `Facil.unbrotli` checks the decoder once and throws a clear error there
  (`Facil.brotli_decoder_works()` tells in advance); the tests record their
  brotli round trips as broken on that platform. Compression is not affected.
- `close(server; grace)` no longer leaves a monitor task to be compiled when
  the server finishes closing; a program that exited at that moment could
  hang in Julia's exit (seen about once in 20 runs of the shutdown examples).
- Installing: `Pkg.add` by URL works. The facil.io git submodule is gone (Pkg
  cannot check out a repository that has one); the pinned sources are
  downloaded and verified instead (`deps/fetch_facil.sh` for the patch
  tooling). `deps/build.jl` is now `deps/build_local.jl` and runs when Facil
  is precompiled, so the library is built on first load and rebuilt after a
  change in `deps/shim` or `deps/patches`; `Pkg.build("Facil")` does nothing.
- Memory and thread safety (tests in `test/safety.jl`):
  - `send(ws, msg)` from another thread no longer hangs the process when an
    `on_ready` callback of that WebSocket starts a garbage collection, and
    `unsubscribe(sub)` no longer hangs when that subscription's function does.
  - Ctrl-C at the REPL can no longer land inside one of Facil's lock sections,
    which left the lock held and stopped the reactor.
  - A `Vector{UInt8}` body resized while it was still being sent no longer
    sends freed memory: on Julia 1.11 and later the old memory is kept until
    it is sent; on 1.10 the resize throws.
  - A compressed `ResponseStream` written by two tasks, or written while it
    closes, no longer corrupts or crashes its encoder: its writes take turns,
    and a write after the close throws `Base.IOError`.
  - A task handler that reads a streamed body (`Stream()`) owns its request's
    `extensions`; the reactor no longer adds an internal entry after the
    handler has started.
  - `Facil.connections`, `close`, `reload!` and draining no longer read a
    server's C state after facil.io has freed it.
  - A task handler that finishes after its connection was closed (by
    `close(server)` or a reactor stop) no longer answers another client whose
    connection reused the descriptor and got the same facil.io id (it wraps
    after 128 reuses); that crashed the process.

### HttpTypes

- `isequal` between a `HeaderName` or `HeaderValue` and a string (or bytes) is
  `false`, so that values that are `isequal` hash alike; `==` still compares
  across types. `HttpTypes.standard_header(i)` checks its index.
- Port of the Rust `http` crate 1.5.0 in `lib/HttpTypes`: `HttpMethod`,
  `StatusCode`, `Version`, `HeaderName`, `HeaderValue`, `HeaderMap`, `Uri` and
  its parts, `Extensions`, `Request`, `Response`, and the crate's error types,
  with the crate's tests translated.

### C library

- facil.io pinned at `51287473` with 24 patches (`deps/patches`): temp-file
  cleanup, exact timers, gather-write send path, close races, TLS layer,
  HTTP robustness, file-descriptor capacity, request bodies, WebSocket fixes and
  controls, TLS write buffer, WebSocket performance, kqueue re-arm batching,
  epoll uuid events, a shared HTTP/1.1 read buffer, close-marker race, reactor
  thread wake-up, per-thread kqueues, the slow-reader guard for writes that
  would block, HTTP conformance, WebSocket shutdown, half-closed clients,
  peer info and static files.
- Patch 24 (`static-files`): `If-Modified-Since`, the directory `301`, a
  settable `cache-control` for the public folder, and `.well-known` under
  dotfile denial.
- Patch 23 (`peer-info`): the peer's TCP port at accept, a connection's hook
  state, and the certificate of a TLS client as PEM.
- Patch 22 (`half-close`): the poll loops read what a peer sent before its
  FIN (or reset) instead of closing the connection unread; the C side of the
  half-close fix listed under Server.
- Patch 20 (`http-conformance`) and patch 21 (`websocket-shutdown`): the C
  side of the status line, bodyless status, request line, static file and
  WebSocket close fixes listed under Server.
- Patch 19 (`slow-reader-would-block`): a client that never reads is also
  dropped when a write takes nothing at all, which is what happens on Linux
  loopback.
- Patch 18 (`kqueue-per-thread`): with more than one reactor thread on macOS,
  each thread owns a kqueue and closes only its own descriptors. This fixes a
  `close()` that could hang in the kernel forever (an unkillable process).
- `deps/shim/fjl_async.c`: a paused request is linked to its connection and
  dropped when that closes, instead of being resumed by its id.
- `deps/shim`: the client of a request (`fjl_req_peer`), connection watching
  for disconnect detection (`fjl_async_watch`), a per-server public-folder
  `cache-control`, and `date` on streamed heads. Shim ABI 3.
- A C shim (`deps/shim`) for request reading, no-copy sends, task hand-off,
  bodies, streaming, timers, WebSockets and TLS.
- `deps/build_local.jl` builds the library with the system C compiler.

### Benchmarks and docs

- `bench/scoreboard`: the Node.js comparison (Node `http`/`https`/`cluster`,
  uWebSockets.js, `ws`); see `docs/src/reference/benchmarks.md`. Rows with an approved
  exception carry an `exception` reason in `rows.json` and read EXCEPTION, not
  FAIL. Facil servers start with `JULIA_NUM_GC_THREADS=4` by default
  (`--facil-env` overrides it). Row A15c uses 6 client workers.
- README and a Documenter.jl site in `docs/`, published at
  <https://aryan-juliahub.github.io/Facil.jl/dev/>: getting started and a
  tutorial, task guides, an API reference generated from the docstrings, and
  reference pages. Every example is run by the docs build (`docs/examples`).

### Known problems

- Approved exceptions to the "faster than Node" target: start-up, memory and
  first request (10–13 and variants), JSON building (19, 19a), task handlers at
  light load and uploads through a task (25, 31-p99, 31-cpu), macOS networking
  (7-c10, 26), GC tails (21a-p99, 21a-p999, 32). See `docs/src/reference/limits.md`.
- Julia's garbage collector can free memory that is in use on Apple silicon
  when it has more than one GC thread (seen with Julia 1.13.4; a script
  without packages reproduces it). Run with `--gcthreads=1` there. CI does.
  See the deployment guide.
