# [FAQ and troubleshooting](@id faq)

This page answers the questions that come up first when running Facil, by
symptom. Each answer links to the page with the full explanation.

## Starting

### `SystemError: Facil: listening on 127.0.0.1:8080: Address already in use`

Another process is listening on that port, often an earlier run of your own
server that is still alive.

```sh
lsof -nP -iTCP:8080 -sTCP:LISTEN    # who holds the port
kill <pid>                          # SIGTERM lets a Facil server drain
```

In tests and scripts, do not use a fixed port at all: port `0` asks the
system for a free one.

```@eval
Main.example("faq_port_in_use.jl")
```

A server you closed with `close(server)` frees its port as soon as
`wait(server)` returns.

### `Facil: ... libfacil_julia ... is missing; build it with ...`

The library file was removed after Facil was precompiled. Facil builds it
when it is precompiled, so force that: `touch` the file `src/Facil.jl` of the
package (or delete its folder under `~/.julia/compiled`) and load Facil
again. See [Install](../getting-started/install.md), which also covers the
other installation errors.

### `Facil.jl requires Linux or macOS`

You are on Windows. Use WSL2: [Platform support](platforms.md).

### `the reactor is already running with 1 thread(s) ...`

You passed `reactors = N` to a server after another server (or a
`subscribe`/`publish` call) had already started the reactor with a different
number. The reactor is shared by the whole process. Start the server that
needs `reactors` first, or give every server the same value.

### `UndefVarError: Response not defined` after `using Downloads`

`Downloads` exports its own `Response`, and Julia refuses to pick between two
exported names. Write `import Downloads` and call `Downloads.request(...)`,
or qualify the type as `Facil.Response`.

## Stopping

### Stopping prints a long `signal 2: Interrupt` report

That is how Julia ends any script on Ctrl-C, and it prints the same kind of
report (`signal 15: Terminated`) for SIGTERM. It is not a crash. Facil still
drains: requests in flight finish, and the process exits. At the REPL, Ctrl-C
closes the server cleanly and gives you the prompt back.

### Ctrl-C does nothing

Under `julia -e '...'`, or when your program calls
`Base.exit_on_sigint(false)`, Julia turns Ctrl-C into an exception that does
not reach the task waiting inside `serve`. Send SIGTERM instead, or run the
program from a file. [Shutdown and signals](../guide/shutdown.md) has the
details.

### Requests are cut off at shutdown although I set `shutdown_grace`

On Julia 1.10 and 1.11 the SIGTERM drain cannot finish a handler that was
waiting on a database, another service or `Base.sleep` when the signal
arrived, because Julia's event loop stops once the process starts to exit.
Use Julia 1.12 or later, where the drain finishes every handler, or drain
with `close(server; grace)` before the signal is sent, for example through a
drain endpoint: [Draining before the signal](@ref shutdown-drain-io).

### The process takes seconds to exit after SIGTERM

It is waiting for requests in flight, for up to `shutdown_grace` seconds
(10 by default). A handler that never returns, or one that was waiting on I/O
when the signal arrived (see above), holds the process for the whole grace
period. Lower `shutdown_grace`, or find the handler.

## Slowness

### The first request is slow

Julia compiles your handler the first time each route runs: typically a few
hundred milliseconds. Every later request is fast. Call the handler once
before `serve`, or build a system image:
[Deployment](@ref deployment-startup).

### Why is my handler slow, or why does one slow request stall the others?

Work through these in order.

1. **Is Julia running with one thread?** Start a server with `verbose = true`
   and read the start-up line. If it says `handlers inline` and you did not
   ask for that, you started Julia without `-t`. With one thread every
   handler runs on the event loop, and a handler that waits stalls every
   connection. Start with `julia -t 4`.
2. **Is the server `inline = true` with a handler that blocks?** Anything
   that waits (a database call, `sleep`, a lock, a large computation) must not
   run inline. Remove `inline = true`.
   [Handlers and concurrency](../guide/handlers.md) lists what counts as
   blocking.
3. **Are all threads busy computing?** A task handler that computes occupies
   a thread. With `-t 4`, the fifth concurrent CPU-heavy request waits.
   [`Facil.paused_requests()`](@ref Facil.paused_requests) shows the queue.
   Add threads or make the work cheaper.
4. **Is the handler contending on a lock?** A global lock held during slow
   work turns a parallel server into a serial one. Copy what you need under
   the lock and work outside it.
5. **Is it garbage collection?** Collections pause every thread. If the slow
   requests are rare and a few milliseconds long, see
   [Performance tuning](../guide/performance.md).
6. **Is it the client?** Measuring with `curl` in a loop measures connection
   set-up and process start-up. Use a load-testing tool with keep-alive.

### `Base.sleep` in a handler is inaccurate

`Base.sleep(0.001)` takes about 2.5 ms on macOS. Use
[`Facil.sleep`](@ref), which is accurate to tens of microseconds.

### CPU use is higher than I expected at low traffic

A task-handler server wakes a worker thread for each request, which costs
about 20% more CPU than Node.js at a light, steady load. If your handlers
never block, `inline = true` removes that cost. An idle server uses no CPU.

## Memory

### An idle server uses about 400 MB

That is the Julia runtime with Facil and its dependencies loaded, not the
server: Node.js uses about 50 MB for the same job. Connections add little.
A system image lowers it somewhat (about 324 MB in the
[benchmarks](benchmarks.md), row 10-sysimg). Size containers at 512 MB or
more.

### Memory grows under load

- Clients that do not read their responses: Facil holds the bodies until
  they are sent. `max_pending_output` disconnects such clients;
  [`Facil.pinned_bodies()`](@ref Facil.pinned_bodies) shows how many bodies are
  held.
- WebSocket clients that do not read broadcasts: set
  [`Facil.slow_subscribers!`](@ref).
- Large uploads held in memory: lower `body_in_memory`, or use
  [`Spool`](@ref) or [`Stream`](@ref).
- Your own caches and globals.

## Responses

### What reason phrase does an unusual status get?

Every status from 100 to 999 is sent with the number you returned. The reason
phrase is `canonical_reason(status)` (`418 I'm a teapot`), or `Unknown` for a
code without one (`299 Unknown`).

### My 204 (or 304) response lost its body

Those statuses, and `1xx`, cannot carry content, so Facil sends them without
a body and without `content-length`, whatever the `Response` holds.

### `Response(404)` throws `ArgumentError`

One integer is ambiguous between a status and a body. Write
`Response(StatusCodes.NOT_FOUND)` or `Response(404, "not found")`.

### My JSON is served as `text/plain`

A `String` body gets `text/plain; charset=utf-8` unless you set a
`content-type`. Add `headers = [header.CONTENT_TYPE => "application/json"]`.
See [JSON](../guide/json.md).

### Every response has a `last-modified` header set to now

facil.io adds it when you do not set one. Caches may take it as "this just
changed". Set your own `last-modified` or `cache-control` on responses you
want cached.

### How do I get the client's IP address?

[`client_address`](@ref)`(req)` returns `(ip = "203.0.113.7", port = 51234)`.
Behind a reverse proxy that is the proxy's address: read the
`x-forwarded-for` header the proxy sets instead.

### How do I read a query parameter or a decoded path?

[`query_param`](@ref)`(req, "name")` is the decoded first value of a query
parameter, [`query_params`](@ref)`(req)` all of them in order, and
[`decoded_path`](@ref)`(req)` the percent-decoded path (`nothing` for an
encoded `/` or NUL, a bad escape or invalid UTF-8). `query(uri(req))` and `path(uri(req))` stay as
the client sent them. See [Query strings and forms](../guide/urls-and-forms.md).

## HTTPS

### `ArgumentError: certificate: no such file "..."`

The path given to [`TLSConfig`](@ref) does not exist. Relative paths are
relative to the directory the process was started in.

### `TLSError: certificate: the private key does not match the certificate`

The key file belongs to another certificate. Check that both came from the
same issuance.

### `TLSError: certificate: the private key could not be read (wrong or missing password?)`

The key is encrypted. Pass `password = "..."`.

### `ArgumentError: HTTPS needs reactors = 1`

TLS connections are safe on one reactor thread only. Remove `reactors`, or
terminate TLS in a proxy.

### Browsers say the certificate is not trusted

A self-signed certificate is not trusted by anyone. Use it for development
with `curl --cacert cert.pem`, and a certificate from a public authority
(for example Let's Encrypt) in production. [HTTPS](../guide/tls.md) shows
both.

### Renewed certificates are not picked up

Files are read when the `TLSConfig` is built. Call [`reload!`](@ref) after
renewing.

## WebSockets

### The upgrade works locally but fails behind a proxy

The proxy must forward the `Upgrade` and `Connection` headers and speak
HTTP/1.1 to Facil. See the nginx example in
[Deployment](../guide/deployment.md).

### `send` returns `false`

The connection is closing or closed. `send` never throws for that; check the
return value, or drop the connection from your own tables in `on_close`.

## Getting help

- The repository: <https://github.com/aryan-juliahub/Facil.jl>
- When reporting a problem, include the start-up line printed by
  `verbose = true` (it shows threads, handler mode and limits), your Julia
  version and operating system, and the smallest program that shows it.
