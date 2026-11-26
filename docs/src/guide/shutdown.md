# [Graceful shutdown and signals](@id shutdown-guide)

This page shows how to stop a server: at once, or after letting requests in
progress finish; what Ctrl-C and SIGTERM do; and what happens to WebSockets,
event streams and streamed responses when a server closes.

## The short version

- A server started with [`serve`](@ref) stops on SIGTERM (`kill <pid>`), after
  giving requests in progress `shutdown_grace` seconds (default 10). This is
  what process managers send.
- **The SIGTERM drain only saves handlers that are computing or waiting in
  `Facil.sleep`.** A handler that is waiting on a socket, a file, a child
  process or `Base.sleep` when the signal arrives never finishes. If your
  handlers do I/O, drain with `close(server; grace)` before the process is
  signalled: see [Draining handlers that do I/O](@ref shutdown-drain-io).
- A server started with [`serve!`](@ref) stops when you call `close(server)` or
  `close(server; grace = seconds)`.
- Ctrl-C stops `serve` cleanly in the REPL. In a script it ends the process
  less gracefully; see [Ctrl-C](shutdown.md#Ctrl-C).

## Closing a server

`serve!` returns a [`Server`](@ref). These functions work on it:

| Call | Effect |
|---|---|
| `close(server)` | Stop accepting connections and close the open ones once their queued output is sent. Returns at once. |
| `close(server; grace = s)` | Stop accepting, let requests in progress finish, close what is left after `s` seconds. Returns at once. |
| `wait(server)` | Block until the server has fully stopped. |
| `isopen(server)` | `true` until `close` is called. |

Closing takes a moment (up to about a second) because the reactor finishes the
connections on its next pass. Call `wait(server)` if what you do next depends
on the port being free. Calling `close` again, in either form, does nothing.

`close(server)` without `grace` does not wait for handlers. A request whose
handler is still running loses its connection; the handler runs to the end and
its response is discarded.

## Letting requests finish

With `grace`, the server drains:

1. It stops accepting new connections. New clients are refused.
2. Idle keep-alive connections get a 2-second timeout: one that stays silent
   is closed 2 to 3 seconds into the drain.
3. Each request in progress runs to completion and gets its response, sent
   with `connection: close`.
4. After `grace` seconds, whatever is still open is closed.

`wait(server)` returns as soon as the last connection is gone, which is usually
long before the grace period ends. If a client is holding an idle keep-alive
connection open, that is 2 to 3 seconds.

```@eval
Main.example("shutdown_grace.jl")
```

```sh
$ curl http://127.0.0.1:8080/report &          # takes one second
$ curl -X POST http://127.0.0.1:8080/shutdown
shutting down
report done
```

The program prints `server closed; cleaning up` and exits about a second
later, not after the full five.

Pick a grace period longer than your slowest normal request and shorter than
what your process manager allows before it sends SIGKILL (systemd's
`TimeoutStopSec` defaults to 90 s, Kubernetes' `terminationGracePeriodSeconds`
to 30 s, `docker stop` to 10 s).

## SIGTERM

A process blocked in `serve` drains on SIGTERM the same way, using the
`shutdown_grace` keyword (default 10 seconds):

```@eval
Main.example("shutdown_sigterm.jl")
```

```sh
$ curl http://127.0.0.1:8080/ &
$ kill -TERM <pid>
finished
```

What happens, in order:

1. Julia receives the signal and starts to exit. Julia prints its own signal
   report to stderr first (on Julia 1.13, `signal 15: Terminated` and one
   stack trace per thread). This is noise from Julia, not an error.
2. Facil's exit hook drains every open server in the process as described
   above. With `verbose = true` it logs
   `Facil: signal received; closing 1 server(s), up to 5.0 s for open requests`.
3. The process ends. Its exit status is that of a process killed by SIGTERM
   (143 in a shell), not 0.

Details worth knowing:

- The drain is tied to `serve`. A process that only uses `serve!` (and waits
  some other way) exits on SIGTERM without draining. End your program with a
  `serve` call, or with `wait(server)` plus your own shutdown trigger as in the
  example above.
- If several servers are open, all of them drain together, and the longest
  `shutdown_grace` among them applies.
- Code after `serve(...)` does **not** run on SIGTERM: the process exits from
  inside `serve`. Put cleanup in an `atexit` hook if you need it.
- SIGKILL cannot be handled; requests in progress are lost.

!!! warning "Handlers that wait on I/O do not survive the SIGTERM drain"
    Once Julia has received SIGTERM it runs its exit hooks and its event loop
    stops turning. Facil's drain runs inside such a hook. A handler that is
    computing, or waiting in [`Facil.sleep`](@ref), still finishes and its
    response is sent. A handler waiting on anything Julia's event loop
    delivers does not: a socket (a database or HTTP client), a child process,
    `Base.sleep`, a `Timer`. It never wakes up, its client gets no response,
    and the process waits out the whole `shutdown_grace` before exiting.

    Measured on Julia 1.13 with a one-second handler and `shutdown_grace = 5`:
    with `Facil.sleep(1)` or a one-second computation the client got its
    response and the process exited after 0.8 s; with `Base.sleep(1)`, a
    socket read or a child process (`run`) the client got nothing and the process
    exited after 5 s. On Julia 1.10 the drain was less reliable still: in our
    runs even a computing handler was sometimes cut off.

## [Draining handlers that do I/O](@id shutdown-drain-io)

`close(server; grace)` called from ordinary code, while the process is still
running normally, drains every kind of handler. So give your service a way to
be told to drain, and have whatever stops the process use it first. An
authenticated endpoint is the simplest:

```@eval
Main.example("shutdown_drain.jl")
```

```sh
$ curl http://127.0.0.1:8080/ &
$ curl -X POST -H 'X-Drain-Token: change-me' http://127.0.0.1:8080/admin/drain
draining
finished
```

The handler here waits in `Base.sleep`, which the SIGTERM drain would not
survive. After the drain request the server stops accepting, the request in
flight gets its `finished`, `wait` returns, and the program ends with exit
status 0. Under systemd, call the endpoint from `ExecStop=`; in Kubernetes,
from a `preStop` hook ([Deployment](deployment.md)). SIGTERM then arrives at a
process that is already idle or gone.

Facil cannot tell you who is calling (there is no client address), so protect
the endpoint with a secret, and do not expose it through your reverse proxy.

## Ctrl-C

What Ctrl-C (SIGINT) does depends on how Julia runs:

| How Julia runs | Ctrl-C |
|---|---|
| In the REPL | `serve` closes the server and returns; you are back at the prompt. |
| `julia server.jl` | Julia prints a signal report (`signal 2: Interrupt` and stack traces) and exits. Facil's exit hook still drains the servers first. Exit status 130. |
| `julia -e '...'`, or after `Base.exit_on_sigint(false)` | Nothing. The interrupt does not reach `serve` and the server keeps running. Stop it with SIGTERM. |

So Ctrl-C is fine while you develop. For anything automated, send SIGTERM.

## Long-lived connections

WebSockets, event streams and streamed responses have no "request in
progress" that finishes by itself, so they hold a draining server open until
the grace period ends. Then they are cut:

| Connection | On `close(server)` or when the grace period ends |
|---|---|
| WebSocket | Dropped without a close frame. `on_close` runs; `on_shutdown` does not. |
| Event stream ([`sse`](@ref)) | Closed. `isopen(s)` turns `false` and [`write_event`](@ref) returns `false`, so the function should return. |
| Streamed response ([`stream`](@ref)) | Closed without the terminating chunk; the client sees an incomplete body. `write` throws an `IOError`. |

If you want these to end sooner or more politely, end them yourself before
closing the server:

- Write stream and event-stream functions as loops over `isopen`, and give
  them a flag to stop on (for example a `Threads.Atomic{Bool}` that your
  shutdown code sets).
- For WebSockets, close each connection with a code (`close(ws; code = 1001)`),
  or tell clients first through a channel they subscribe to
  ([`publish`](@ref)).

`on_shutdown` and the `1001` close do happen in one case: when the process
exits normally (the script ends, or `exit()` is called) while connections are
open.

## The reactor outlives servers

Closing a server closes its listener and its connections, nothing else. The
reactor thread, the timer thread, [timers](timers.md) and
[subscriptions](pubsub.md) keep running for the life of the process, and you
can start new servers afterwards (on the same port, once `wait(server)` has
returned).

A process whose script reaches its end exits promptly even with servers,
timers, subscriptions and connections still open.

## See also

- [Deployment](deployment.md) for systemd and container settings.
- [Errors and logging](errors.md).
- API: [`serve`](@ref), [`serve!`](@ref), [`Server`](@ref),
  [`Facil.drain_server!`](@ref).
