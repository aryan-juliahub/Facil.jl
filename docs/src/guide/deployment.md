# [Deployment](@id deployment-guide)

This guide takes a working Facil program to production: how to start it, how
many threads to give it, how to run it under systemd or in a container, what
to put in front of it, how to check its health, and how to cut its start-up
time.

## The server program

A production entry point is a small script. This one is used throughout the
page:

```@eval
Main.example("deploy_app.jl")
```

Things worth copying:

- **Address and port come from the environment**, so the same file runs on
  your laptop, under systemd and in a container.
- **`/health`** answers without touching anything else. Load balancers and
  orchestrators poll it.
- **The handler is called once before `serve`**, so Julia compiles it before
  the first client arrives. See [Start-up time](@ref deployment-startup).
- **`shutdown_grace`** is how long requests in flight get when the process is
  asked to stop.
- **Limits are set for this service**, not left at the general defaults.
  [Security](security.md) goes through them.

Bind to `127.0.0.1` when a reverse proxy on the same machine is the only
client, and to `0.0.0.0` in a container or when clients connect directly.

## Threads

```sh
julia -t 4 --gcthreads=4 --project=. server.jl
```

- **`-t N`** (or `JULIA_NUM_THREADS=N`) sets Julia's threads, which run your
  task handlers. Never run a task-handler server with one thread: Facil then
  runs handlers inline on the event loop, and one slow handler stalls every
  connection ([Handlers and concurrency](handlers.md)).
  - Handlers that mostly wait (database, other services): 2 to 4 threads
    carry thousands of concurrent requests.
  - Handlers that compute: one thread per core you want to use, and leave a
    core for the reactor.
  - `-t auto` uses every core, which is rarely what a container with a CPU
    quota wants. Set the number explicitly there.
- **`--gcthreads=N`** (or `JULIA_NUM_GC_THREADS=N`) sets the garbage
  collector's threads. With `-t 1` Julia collects with a single thread and
  every pause is longer than it needs to be; give an inline server
  `--gcthreads=4`. With `-t 4` or more Julia already uses several.
  [Performance tuning](performance.md) has the measurements.
- **`reactors`** stays at 1 unless you have measured that the event loop is
  the bottleneck.

!!! warning "Apple silicon: use one GC thread"
    On macOS with an Apple silicon CPU, run Julia with `--gcthreads=1` (or
    `JULIA_NUM_GC_THREADS=1`). Julia's collector has a race between its
    threads when they sweep in parallel: rarely, a full collection releases
    memory that is still in use and the process crashes with a segmentation
    fault in `gc_setmark_pool_`. It was seen with Julia 1.13.4 and the code is
    the same in 1.12 and 1.13; it needs several GC threads and a heap of a few
    megabytes, and it is not specific to Facil. A script with no packages
    that calls `GC.gc(true)` in a loop crashed in 4 of 74 one-minute runs on
    a macOS arm64 CI machine and in none of 40 with one GC thread. Linux, on
    x86-64 and on ARM, did not crash in the same runs.

Facil does not fork worker processes. One process serves one port and scales
with threads.

## systemd

```@eval
Main.example("manual/notes.service")
```

- `systemctl stop` sends SIGTERM. [`serve`](@ref) then stops accepting, lets
  requests in flight finish for up to `shutdown_grace` seconds, and the
  process exits with status 143. Julia writes a `signal 15: Terminated`
  report to the journal on the way out; it is not an error. `TimeoutStopSec` must be longer than
  `shutdown_grace`, and `SuccessExitStatus=143` tells systemd that this exit
  is a clean stop.
- **On Julia 1.10 and 1.11 the SIGTERM drain cannot finish handlers that are
  waiting on I/O** (a database, another service): see
  [Draining before the signal](@ref shutdown-drain-io). There, give
  the service a drain endpoint and add
  `ExecStop=/usr/bin/curl -fsS -X POST -H "X-Drain-Token: ..." http://127.0.0.1:8080/admin/drain`
  to the unit, so that requests are drained before systemd sends the signal.
  Julia 1.12 and later need none of this.
- Facil writes its own messages (start-up line, handler errors) to stderr,
  which systemd sends to the journal: `journalctl -u notes`.
- `LimitNOFILE` bounds the number of open connections; each one is a file
  descriptor. facil.io raises the soft limit to the hard limit at start-up.

This unit file is not executed by the documentation build.

## Containers

```@eval
Main.example("manual/Dockerfile")
```

- Use the **exec form** of `ENTRYPOINT` so that Julia is PID 1 and receives
  the SIGTERM that `docker stop` and Kubernetes send. A shell-form entry point
  swallows it and your requests are cut off after the stop timeout.
- Set **`JULIA_NUM_THREADS` explicitly** to match the container's CPU limit.
- The build stage needs a C compiler because Facil's C library is built from
  source for now; the final image does not.
- Precompiling in the build stage (`Pkg.precompile()`) keeps that cost out of
  container start-up.
- For Kubernetes, point `livenessProbe` and `readinessProbe` at `/health`,
  set `terminationGracePeriodSeconds` above `shutdown_grace`, and call your
  drain endpoint from a `preStop` hook if handlers do I/O and Julia is older
  than 1.12.

This Dockerfile is not built by the documentation build.

## Behind a reverse proxy

Facil serves HTTPS itself ([HTTPS](tls.md)), so a proxy is optional. Put one
in front when you want HTTP/2 or HTTP/3 towards browsers (Facil speaks
HTTP/1.1 only), several services on one address, or certificate management in
one place.

```@eval
Main.example("manual/nginx.conf")
```

What matters, whichever proxy you use:

- **Speak HTTP/1.1 with keep-alive to Facil.** nginx defaults to HTTP/1.0 and
  a new connection per request, which wastes most of Facil's speed.
- **Keep the proxy's idle timeout below Facil's `timeout`** (40 seconds by
  default). Otherwise Facil may close an idle connection at the moment the
  proxy reuses it, and the client sees a `502`.
- **Pass `Upgrade` and `Connection` for WebSocket paths**, and raise the read
  timeout: an idle WebSocket is normal.
- **Turn off response buffering for event streams and streamed responses**,
  or events arrive in bursts.
- **Facil does not interpret `X-Forwarded-For` or `X-Forwarded-Proto`.** They
  are ordinary headers: read them with `get(headers(req), "x-forwarded-for", nothing)`,
  and only trust them when the proxy is the only way to reach the server.
- **Match body limits** (`client_max_body_size` and `max_body_size`), so the
  client gets the same answer whichever side refuses.

This configuration is not executed by the documentation build.

## Health checks and rolling restarts

- **Liveness**: `GET /health` returning `200` shows that the event loop and a
  worker are alive.
- **Readiness**: if your service needs something before it can answer (a
  database pool, a warm cache), start listening only after it is ready, or
  answer `503` from `/health` until then.
- **Draining**: on SIGTERM the server stops accepting at once, so a load
  balancer sees connection refusals and moves on. Requests already in flight
  finish within `shutdown_grace` (on Julia 1.10 and 1.11 only if their
  handlers are not waiting on I/O; drain those with `close(server; grace)`
  first, see [Shutdown and signals](@ref shutdown-drain-io)). For a load balancer that needs warning, fail `/health` first,
  wait one check interval, then stop the process.
- [`Facil.connections(server)`](@ref Facil.connections) and the other
  [counters](../api/tuning.md) make a metrics endpoint in a few lines.

[Shutdown and signals](shutdown.md) covers the stop sequence in detail.

## [Start-up time](@id deployment-startup)

A Julia process takes longer to start than a Node.js one, and the first
request to each route waits for compilation. Measured on the
[benchmark machine](../reference/benchmarks.md) (rows 12 and 13):

| | Plain `julia` | With a system image |
|:--|:--|:--|
| Process start to first response | 701 ms | 264 ms |
| First request, once the server is up | 310 ms | 5.2 ms |

Later requests are not affected. Three things help, in order of effort.

**1. Call the handler before serving.** The line
`app(Request(Methods.GET, "/health", ""))` in the program above compiles the
handler and the routes it touches before the port opens. Call it once per
route that matters. It costs one line and moves the delay from the first
client to start-up.

**2. Precompile in your own package.** If your application is a package, a
[PrecompileTools](https://github.com/JuliaLang/PrecompileTools.jl) workload
that calls the handler stores the compiled code with the package, so start-up
does not pay for it either.

**3. Build a system image** with
[PackageCompiler](https://github.com/JuliaLang/PackageCompiler.jl). Split the
application from the `serve` call so that a warm-up script can load it:

```@eval
Main.example("deploy_app_routes.jl")
```

The warm-up script starts the app, sends one request per route and stops:

```@eval
Main.example("deploy_warm.jl")
```

The build script:

```@eval
Main.example("manual/deploy_sysimage.jl")
```

```sh
julia --project=. -e 'using Pkg; Pkg.add("PackageCompiler")'
julia --project=. deploy_sysimage.jl                           # several minutes
julia -t 4 -J app_sysimage.so --project=. server.jl
```

Rebuild the image whenever Facil, Julia or your dependencies change. The
warm-up script runs in the documentation build; the image build itself takes
minutes and was run by hand.

## Memory

An idle Facil process uses about 380 MB of resident memory, most of it the
Julia runtime (row 10 of the benchmarks; Node.js uses about 50 MB). Each idle
keep-alive connection adds little, and an idle WebSocket about 285 bytes
(row A28). Size containers accordingly: 512 MB is a sensible floor.

## Windows

Facil does not run natively on Windows, because facil.io has no Windows port.
Run it inside [WSL2](https://learn.microsoft.com/windows/wsl/install), where
it is an ordinary Linux process: install Julia in the WSL distribution, follow
[Install](../getting-started/install.md) there, and reach the server from
Windows at `localhost`. HttpTypes works natively on Windows. See
[Platform support](../reference/platforms.md).

## Checklist

- `julia -t N` with `N >= 2`, set explicitly in containers
- address and port from the environment; `127.0.0.1` behind a local proxy
- limits set for the service (`max_body_size`, `timeout`)
- `/health` endpoint, polled by whatever restarts the process
- SIGTERM reaches Julia; the supervisor waits longer than `shutdown_grace`
- a drain endpoint called before the stop signal, if handlers do I/O
- proxy uses HTTP/1.1 keep-alive with an idle timeout below `timeout`
- open-file limit above the expected number of connections
- handler called once before `serve`, or a system image

## See also

- [Handlers and concurrency](handlers.md), [Performance tuning](performance.md)
- [Shutdown and signals](shutdown.md), [Security](security.md), [HTTPS](tls.md)
- [Configuration](../reference/configuration.md) for every `serve` keyword
