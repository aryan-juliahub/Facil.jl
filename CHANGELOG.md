# Changelog

## Unreleased

First version. Nothing has been released or registered yet.

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
- Static files with `public_folder` and `sendfile`: ETag, `Last-Modified`,
  conditional and single-range requests, precompressed `.gz` files,
  `Facil.register_mime!`.
- Streaming responses with `stream` (chunked on HTTP/1.1, keep-alive kept).
- Server-sent events with `sse`, `write_event`, `last_event_id`.
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
- Task-handler worker pool fixes: a steady stream of newly spawned tasks can no
  longer starve older ones (Julia's run queue is not first-in first-out), and a
  runner yields its thread when other tasks wait for one. Streamed gzip (row 27)
  went from 2.8k to 10.3k req/s.
- Streamed request-body chunks come from a pool of reused buffers instead of a
  new array per chunk.
- Removed the idle-thread spin override: Facil no longer reads Julia's symbol
  table or changes Julia runtime variables. For light-load handlers use
  `inline = true`, and for streamed uploads `Stream(on_chunk)`.

### HttpTypes

- Port of the Rust `http` crate 1.5.0 in `lib/HttpTypes`: `HttpMethod`,
  `StatusCode`, `Version`, `HeaderName`, `HeaderValue`, `HeaderMap`, `Uri` and
  its parts, `Extensions`, `Request`, `Response`, and the crate's error types,
  with the crate's tests translated.

### C library

- facil.io pinned at `51287473` with 19 patches (`deps/patches`): temp-file
  cleanup, exact timers, gather-write send path, close races, TLS layer,
  HTTP robustness, file-descriptor capacity, request bodies, WebSocket fixes and
  controls, TLS write buffer, WebSocket performance, kqueue re-arm batching,
  epoll uuid events, a shared HTTP/1.1 read buffer, close-marker race, reactor
  thread wake-up, per-thread kqueues, and the slow-reader guard for writes that
  would block.
- Patch 19 (`slow-reader-would-block`): a client that never reads is also
  dropped when a write takes nothing at all, which is what happens on Linux
  loopback.
- Patch 18 (`kqueue-per-thread`): with more than one reactor thread on macOS,
  each thread owns a kqueue and closes only its own descriptors. This fixes a
  `close()` that could hang in the kernel forever (an unkillable process).
- A C shim (`deps/shim`) for request reading, no-copy sends, task hand-off,
  bodies, streaming, timers, WebSockets and TLS.
- `deps/build.jl` builds the library with the system C compiler.

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
