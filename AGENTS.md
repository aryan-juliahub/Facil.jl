# AGENTS.md

Read this first, whether you are a coding agent or a new contributor. Part 1 is
for writing a server with Facil; Part 2 is for changing Facil itself. Depth lives
in [`docs/src/`](docs/src/index.md); this file is the map and the rules.

Facil.jl is an HTTP/1.1, WebSocket, SSE and TLS server for Julia. The sockets,
event loop and parser are [facil.io](https://github.com/boazsegev/facil.io) 0.7
(C, patched); request and response types come from HttpTypes (`lib/HttpTypes`, a
pure-Julia port of the Rust `http` crate 1.5.0), which Facil re-exports.

---

# Part 1: Using Facil in an app

## Setup

Facil is not registered and has no prebuilt binary yet, so it needs a C compiler
(`cc`, or set `CC`) and a local build. Linux and macOS only, Julia 1.10 or later.
On Windows, run inside WSL2 (loading Facil natively stops with an error).

```sh
git clone --recurse-submodules https://github.com/aryan-juliahub/Facil.jl
cd Facil.jl
julia --project -e 'using Pkg; Pkg.instantiate()'
julia --project deps/build.jl
```

## Smallest server

```julia
using Facil

serve("127.0.0.1", 8080) do req
    Response(StatusCodes.OK, "hello")
end
```

Run it with threads: `julia -t 4 --project hello.jl`. `serve` blocks until Ctrl-C
or SIGTERM. `serve!` takes the same arguments, returns a `Server` at once, and
port `0` picks a free port (`port(server)` tells which).

## Handler contract

| | |
|---|---|
| Input | `req::Request{String}`: `method(req)`, `uri(req)`, `headers(req)`, `body(req)` |
| Output | a `Response` whose body is a `String`, `Vector{UInt8}` or `nothing`; or a plain `String` (sent as 200 `text/plain`) |
| Also valid outputs | what `stream`, `sse`, `sendfile` and `websocket` return |
| Throwing, or returning anything else | 500; logged to stderr once per error type every 10 s |
| Routing | none built in: branch on `method(req)` and `path(uri(req))` |
| Query string | `query(uri(req))` is raw text or `nothing`; nothing is percent-decoded (use URIs.jl) |
| Headers Facil sets | `content-length` always; `content-type` when a non-empty body has none (`text/plain; charset=utf-8` for strings, `application/octet-stream` for bytes) |

```julia
using Facil

function app(req)
    m, p = method(req), path(uri(req))
    if m == Methods.GET && p == "/"
        Response(StatusCodes.OK, "home")
    elseif m == Methods.POST && p == "/echo"
        Response(StatusCodes.OK, body(req); headers = [header.CONTENT_TYPE => "application/octet-stream"])
    else
        Response(StatusCodes.NOT_FOUND)
    end
end

server = serve!(app, "127.0.0.1", 8080)
```

## Choices that matter

| Need | Use | Notes |
|---|---|---|
| Handler may block (I/O, locks, waits) | default `inline = false` | Runs on a Julia task. Needs `julia -t N` with N > 1; with one thread handlers run inline regardless. |
| Short, non-blocking handler | `inline = true` | Runs on the reactor thread: cheapest, but one blocking call stalls every connection on that thread. |
| More event-loop threads | `reactors = N` | Process-wide, fixed by the first server; a later server asking for another number throws. HTTPS requires `reactors = 1`. |
| Small or medium request body | `Buffer()` (default) | `body(req)` is a `String`. Over `body_in_memory` (16 MiB) gives 413. |
| Large upload, read in the handler | `before_body = head -> Stream()` | Read with `body_chunks(req)` or `body_stream(req)`; a task handler starts when the head arrives. |
| Large upload, fastest | `Stream(on_chunk)` | `on_chunk(bytes)` runs on the reactor; `bytes` is valid only during the call; must not block. |
| Upload to disk | `Spool()` | `body_stream(req)` is an `IOStream` on an unlinked temp file. |
| Refuse early | `Reject(status)` | 4xx or 5xx only; decided from the `RequestHead` (`head.content_length`, `-1` if chunked). |
| Body of unknown length | `stream(req) do io ... end` | Chunked on HTTP/1.1. `write`, `flush`; `isopen(io)` is false once the client left. |
| Server-sent events | `sse(req) do s ... end` | `write_event(s; data, event, id, retry)`, `last_event_id(s)`. Always on its own task. |
| WebSocket | `Facil.is_upgrade(req)` then `websocket(req; on_open, on_message, on_close)` | Callbacks run on the reactor and must not block; `spawn = true` moves them to tasks. `send(ws, msg)` from any thread. |
| Fan-out to WebSocket clients | `subscribe(ws, channel)`, `publish(channel, msg)` | No Julia code runs per message. Process-local. |
| HTTPS | `tls = TLSConfig(cert, key; ...)` | Paths or PEM text, checked at construction. `reload!(server; cert, key)` rotates certificates live. |
| Static files | `public_folder = dir`, or `sendfile(path)` from a handler | ETag, `last-modified`, conditional and single-range requests, `.gz` siblings. |
| Compression | `compress = true` or `CompressOptions(...)` | zstd, brotli or gzip by `Accept-Encoding`; skips bodies under 1 KiB and non-text types. |
| Short waits, timers | `Facil.sleep(s)`, `every(f, ms)`, `Facil.Timer(cb, delay; interval)` | Timed by a C timer thread. |
| Shutdown | `close(server; grace = seconds)`, then `wait(server)` | Stops accepting, lets requests finish. `serve` does this on SIGTERM with `shutdown_grace` (10 s). |

All `serve!` keywords and their defaults are in the `serve!` docstring
(`src/server.jl`): `max_header_size`, `max_body_size`, `timeout`,
`header_timeout`, `max_pending_output`, `verbose`, `gc_headroom`.

## Mistakes to avoid

- **`Response(404)` throws** (`Response(::Integer)` is ambiguous). Write
  `Response(StatusCodes.NOT_FOUND)` or `Response(StatusCode(404))`. With a body,
  `Response(404, "gone")` is accepted, but prefer the named constant.
- **Constants live in submodules:** `Methods.GET`, `StatusCodes.OK`,
  `Versions.HTTP_11`, `header.CONTENT_TYPE` (lower-case `header`). There is no
  bare `GET` or `OK`.
- **The method type is `HttpMethod`.** `Method` is Julia's own reflection type.
- **Never mutate a body after returning it,** or a byte vector after writing it
  to a stream. Bodies are sent without a copy and may still be in flight.
- **Do not block on the reactor:** not in an `inline = true` handler, a WebSocket
  callback (without `spawn = true`), an `on_chunk` function, or a
  `subscribe(f, channel)` callback (without `spawn = true`).
- **`Base.sleep` is coarse** (about 2.5 ms for `sleep(0.001)` on macOS). Use
  `Facil.sleep` in task handlers. Neither belongs in an inline handler.
  `Facil.sleep`, `Facil.Timer` and `Facil.is_upgrade` are not exported; qualify them.
- **Start Julia with threads.** Without `-t N`, task handlers silently become
  inline handlers (`verbose = true` prints a note).
- **Set `content-type` for JSON yourself;** a `String` body defaults to `text/plain`.
- **A client that disconnects is not noticed** while its handler runs; there is
  no cancellation. In `stream` and `sse`, check `isopen`.
- **HTTP/1.1 only.** No HTTP/2, no router, no HTTP client, no cookie helpers, no
  worker processes. A `Host` header is required (400 without it).
- **HTTP.jl handlers do not port unchanged;** see
  [`docs/src/migrating_from_http_jl.md`](docs/src/migrating_from_http_jl.md).

## Where the full docs are

| Topic | File |
|---|---|
| One page per feature, each with a tested example | [`docs/src/guide/`](docs/src/guide/) (`bodies`, `threads`, `streaming`, `sse`, `websockets`, `pubsub`, `tls`, `static`, `compression`, `shutdown`, `gc`, `routing`, `json`, `query`) |
| HttpTypes names, Rust to Julia | [`docs/src/httptypes.md`](docs/src/httptypes.md) |
| Limits and what is not included | [`docs/src/limits.md`](docs/src/limits.md) |
| API reference (docstrings) | [`docs/src/api.md`](docs/src/api.md), or `?serve!` in the REPL |
| Benchmark numbers | [`bench/scoreboard/RESULTS.md`](bench/scoreboard/RESULTS.md) |

---

# Part 2: Changing Facil

## Repo map

| Path | What it is |
|---|---|
| `src/Facil.jl` | Module, exports, `__init__` order. One file per feature beside it. |
| `src/libfjl.jl` | Finds and loads the C library, ABI check, `@gcsafe_ccall`, C struct mirrors. |
| `src/reactor.jl`, `server.jl`, `async.jl` | Reactor lifecycle; `serve!` and the request callback; the task-handler worker pool. |
| `src/body.jl`, `streaming.jl`, `sse.jl`, `websockets.jl`, `pubsub.jl`, `tls.jl`, `static.jl`, `compress.jl`, `timers.jl`, `signals.jl` | The features named. |
| `deps/facil.io` | Submodule pinned at `51287473`. Never edited. |
| `deps/patches/` | 19 patches, applied in the order of `series` by `apply.sh` to a copy. `README.md` has one row per patch. |
| `deps/shim/` | `fjl_*.c/h`: the C layer Julia calls (`fjl.h` holds `FJL_ABI`). |
| `deps/build.jl` | Builds `deps/usr/lib/libfacil_julia.{dylib,so}` from the patched copy plus the shim. |
| `deps/build_tarballs.jl`, `deps/yggdrasil/` | Packaging for a future `facil_julia_jll`. |
| `lib/HttpTypes/` | Separate package with its own `Project.toml` and tests. No dependencies; runs on Windows too. |
| `test/*.jl` | Facil suite; `runtests.jl` lists the files. Real servers on fixed ports, checked with `curl` and Node clients. |
| `test/patches/` | Suites that drive the patched facil.io objects directly, without Julia. |
| `bench/scoreboard/` | The Node.js comparison: `rows.json`, `run.sh`, `RESULTS.md`, `chart.py`. |
| `docs/` | Documenter site. `docs/src/assets/bench-*.svg` are generated by `chart.py`. |
| `scripts/linux_smoke.sh` | Build and test on a Linux box or container. |

## Build the C library

```sh
julia --project=. deps/build.jl             # no-op when inputs are unchanged
julia --project=. deps/build.jl --force --verbose
```

`build.jl` hashes the facil.io sources, `deps/patches/`, `deps/shim/`, itself,
the compiler and the OpenSSL paths, and skips the build when the hash matches.
Julia never rebuilds for you. Run it after:

- editing anything in `deps/shim/` or `deps/patches/`, or moving the submodule;
- switching Julia versions against the same checkout (the library links that
  Julia's OpenSSL, so build again when you switch back);
- a fresh clone.

If a shim change alters a struct or signature Julia mirrors, change both sides
and bump `FJL_ABI` in `deps/shim/fjl.h` and `src/libfjl.jl` together; loading
refuses a mismatch. `Facil.fjl_build_id()` shows the facil.io commit and patch
hash of the loaded library. Needs zlib headers on Linux (`zlib1g-dev`).

## Change facil.io: the patch series

Never edit `deps/facil.io`. To change facil.io behaviour:

1. `deps/patches/apply.sh /tmp/fio` gives a patched copy in `/tmp/fio/lib`
   (it refuses an existing destination).
2. Copy it, edit the copy, and diff the two trees into
   `deps/patches/NN-short-name.patch` (`diff --git a/lib/facil/... b/lib/facil/...`,
   applied with `patch -p1`).
3. Append the file name to `deps/patches/series` and add a row to
   `deps/patches/README.md`: what it changes and which suite covers it.
4. Add or extend a suite under `test/patches/`, rebuild, run the patch suites
   and the Facil suite.

Add a new patch on top rather than rewriting an earlier one.

## Run the tests

| What | Command | Time |
|---|---|---|
| Facil, full suite | `julia -t 4 --project=. -e 'using Pkg; Pkg.test()'` | about 5 min |
| One file | `julia -t 4 --project=. test/timers.jl` | seconds |
| HttpTypes | `julia --project=lib/HttpTypes -e 'using Pkg; Pkg.test()'` | under 1 min |
| Patch suites, all | `test/patches/run.sh <scratch_dir>` | long |
| Patch suites, some | `test/patches/run.sh <scratch_dir> robust upload ws tls fdreuse` | |
| Hang check | `FDREUSE_RUNS=20 test/patches/run.sh <scratch_dir> fdreuse` | about 20 s for one run of each case |
| Docs | `julia --project=docs docs/make.jl` | seconds; warnings are errors |
| Linux box or container | `scripts/linux_smoke.sh --patches` | |

- The tests need `curl`, `lsof` and `node` on `PATH`. Most files run alone as
  shown; they bind fixed ports between 3400 and 4049, so run one suite at a
  time per machine.
- **Julia 1.10** ignores `[sources]` in `Project.toml`, so `--project=.` cannot
  find HttpTypes. Develop both packages into a scratch environment, as CI does:

  ```sh
  julia +1.10 --project=/tmp/ci110 -e 'using Pkg
      Pkg.develop([PackageSpec(path="lib/HttpTypes"), PackageSpec(path=".")])
      Pkg.build("Facil"; verbose=true)'
  julia +1.10 -t 4 --project=/tmp/ci110 -e 'using Pkg; Pkg.test("Facil")'
  ```

- **Patch suites** build facil.io with `clang` and need OpenSSL 3 headers:
  set `OPENSSL` to a prefix containing `include/openssl` (on macOS the default
  in `test/patches/env.sh` is a path from the original machine). After
  `deps/build.jl`, find one with
  `find deps/build ~/.julia/artifacts -path '*/include/openssl/opensslv.h'`.
  Suites with Node clients read `NODE_MODULES` (default
  `bench/scoreboard/node/node_modules`, which `bench/scoreboard/build.sh` installs).
- **`fdreuse` matters on macOS.** With several reactor threads sharing one
  kqueue, `close()` on a socket could block in the kernel forever, leaving a
  process that ignores even SIGKILL. Patch 18 fixes it by giving each reactor
  thread its own kqueue. Run `fdreuse` (20 runs) after touching anything in the
  reactor, kqueue/epoll, close or wake paths. A run reported as "still running"
  is that hang.

## Threading model and invariants

```
Julia threads                          C threads (pthreads the shim creates)
  handler tasks, worker pool   <-->      reactor thread(s): facil.io event loop
  your code                              timer thread: Facil.sleep, Facil.Timer
        |   fjl_post + wake pipe  --->        |
        |   <--- @cfunction callbacks, uv_async_send
```

- **Reactor threads are not Julia threads.** The shim creates them with
  `pthread_create`; Julia adopts them when a callback first runs. They are in no
  Julia thread pool, and restarting the reactor makes Julia adopt new thread ids,
  so one reactor is kept for the life of the process.
- **Every `@cfunction` callback body is wrapped in `try`/`catch`** and reports
  through `callback_error`, which writes straight to fd 2 (Julia's `stderr`
  needs the event loop). An exception must never unwind into C, and Facil's own
  callbacks never yield or wait on a task while on a reactor thread.
- **A ccall that may block uses `@gcsafe_ccall`** (`src/libfjl.jl`), so a garbage
  collection never waits on it. Its arguments are converted before the call;
  no Julia code may run inside the GC-safe region.
- **Connections are addressed by uuid, never by pointer.** facil.io frees the
  connection object on close; a uuid that is no longer current is ignored. Keep
  `Int` uuids in Julia structs (`WebSocket`, `SSEStream`, `ResponseStream`).
  `http_s*` handles are valid only inside the callback that received them.
- **Julia threads do not touch a connection directly.** They post to the reactor
  with `fjl_post`, which pushes onto a lock-free queue and writes one byte to the
  wake pipe; the reactor drains the queue. A finished task handler goes through
  the resume queue (`fjl_resume`, `fjl_async_done`): only the reactor calls
  `http_resume`, and exactly one of `on_resume` or `on_drop` runs per request.
- **One kqueue per reactor thread on macOS** (patch 18): fd `n` belongs to kqueue
  `n % threads`, and only the owner registers, waits on and closes it. Other
  threads post to the owner's inbox. Linux uses epoll with uuid-tagged events.
- **TLS is flushed only on the reactor thread,** and HTTPS runs with
  `reactors = 1`.
- **Anything C holds must stay rooted in Julia:** response bodies are pinned in
  `PINNED` until facil.io's dealloc callback, servers in `LIVE`, posted closures
  in `POSTED`. Use `GC.@preserve` around pointers passed to C.
- **Task handlers run on a small worker pool** (`src/async.jl`) whose idle
  workers wait in C. Do not replace it with a bare `Threads.@spawn` per request.

## Benchmarks

Numbers are only meaningful on a quiet machine, so:

- **One benchmark at a time,** and nothing else running: no test suite, no
  build, no second agent. The driver checks idle CPU before each run
  (`--idle-min`, default 90%) and marks a busy run NOISY.
- Never quote a number you did not measure with the scoreboard, and report
  failures as failures.

```sh
bench/scoreboard/build.sh                     # clients, pinned Node packages, payloads, certs
bench/scoreboard/run.sh --list                # the rows
bench/scoreboard/run.sh --rows A1,A4 --runs 3 --side both
bench/scoreboard/run.sh                       # all 100 rows, 3 runs per cell
python3 bench/scoreboard/chart.py data        # results/ + rows.json -> chart_data.csv
python3 bench/scoreboard/chart.py             # chart_data.csv -> docs/src/assets/bench-*.svg
```

The scoreboard uses ports 3510 (Node) and 3520 (Facil) and kills only the
servers it started. The target for every row is at least 1.0× the fastest Node
option. A row under target is FAIL unless it carries an `exception` reason in
`rows.json`; those **approved exceptions** are listed in
[`docs/src/limits.md`](docs/src/limits.md). Only the maintainer approves a new
exception: do not add one to make a row stop failing. After new results, update
`RESULTS.md`, regenerate the charts with `chart.py`, and keep the README,
`docs/src/benchmarks.md` and `docs/src/limits.md` in step. Details:
[`bench/scoreboard/README.md`](bench/scoreboard/README.md).

## CI

`.github/workflows/CI.yml`, on every push to `main` and every pull request:

| Job | Runs |
|---|---|
| `test` | Julia 1.10 and latest 1.x on `ubuntu-latest`, `macos-latest` (arm64) and `macos-15-intel`: build the library, HttpTypes tests, Facil tests with `-t 4`. The 1.10 legs use the developed environment above. |
| `httptypes-windows` | HttpTypes tests on Windows; checks that building and loading Facil fail with the WSL2 message. |
| `patches-linux` | `test/patches/run.sh` with `robust upload ws tls fdreuse`: the only run of the epoll, `sendfile` and timerfd paths against the bare C library. |

`BuildTarballs.yml` runs only when started by hand: it builds the
`facil_julia_jll` recipe in `deps/yggdrasil/` with BinaryBuilder and tests Facil
against the result. `CompatHelper.yml` and `TagBot.yml` are the usual package bots.

A run takes about 20 minutes, so batch pushes. Shared runners are slow and
jittery: with `CI=true`, `test/timers.jl` loosens its `Facil.sleep` medians
(1 ms sleep: 4 ms instead of 1.5 ms; 10 ms sleep: 25 ms instead of 11 ms).
Follow that pattern for a timing test: keep the tight local limit and add a
looser one under `CI=true`, rather than loosening it for everyone. Never let a
limit allow a wrong result (a sleep ending early, a lost message).

## Code style

- **Comments: none by default.** Add one only when the code cannot say it; at
  most three lines; say what the code does and the invariant it keeps. No bug
  history and no issue or PR numbers: those go in the commit message.
- **Naming:** Julia functions and keywords in `snake_case`, types in
  `CamelCase`, C shim symbols `fjl_*`, patch files `NN-short-name.patch`.
  HttpTypes keeps the Rust crate's names (`HeaderMap`, `as_str`, `StatusCodes.NOT_FOUND`).
- **Public API** is what `src/Facil.jl` exports plus documented `Facil.name`
  functions. Give every export a docstring and list it in `docs/src/api.md`;
  the docs build fails on an exported docstring that no page includes.
- **No new dependency without need.** Facil depends on HttpTypes, standard
  libraries, a few JLLs and three small packages; HttpTypes depends on nothing.
  HTTP.jl is not a dependency and must not become one.
- Check keyword arguments once, when the server starts, with an `ArgumentError`
  that names the keyword.
- A behaviour change comes with a test, and a `CHANGELOG.md` line when users
  can see it.

## Commits

- Subject: short, imperative, saying what changed for the reader
  (`Fix the GC-safe ccall ABI on Julia < 1.12`). A scope prefix where it helps
  (`CI:`, `Benchmarks:`, `Windows:`).
- Body: a few lines on why, wrapped near 72 columns. Measurements and bug
  history belong here, not in code comments.
- Stage only the files you changed (`git add <path>`, never `git add -A`);
  several agents may share the tree.
- Agent-written commits keep the human as author and carry `Agent-Harness`,
  `Agent-Model`, `Agent-Session`, `Agent-Review: unreviewed` and
  `Co-authored-by` trailers, with values supplied by the harness, not guessed.

## Never

- **Never define `FIO_IGNORE_TLS_IF_MISSING`** or build without OpenSSL: the
  server would silently serve plain HTTP on a port the user asked to be HTTPS.
- **Never fork workers.** facil.io starts with `workers = 1`; more would
  `fork()` a Julia process.
- **Never route HTTP compression through Julia's bundled zlib.** It uses
  libdeflate, zlib-ng, zstd and brotli (JLLs), and runs on the handler's thread.
- **Never edit the `deps/facil.io` submodule** or move its pin without
  re-checking every patch.
- **Never call `http_resume`, or use an `http_s*`, from a Julia thread.**
- **Never stop and restart the reactor** between servers.
- **Never copy a response body "to be safe"** on the send path; the no-copy
  path is deliberate and tested.
- **Never loosen a test, or mark a scoreboard row an exception, to get green.**
- **Never run benchmarks beside other work,** and never start a second test
  suite on the same machine while one is running.
- **Do not create `CLAUDE.md`;** this file is the single entry point.
