# [Graceful shutdown and signals](@id shutdown-guide)

This page shows how to stop a server: at once, or after letting requests in
progress finish; what Ctrl-C and SIGTERM do; and what happens to WebSockets,
event streams and streamed responses when a server closes.

## The short version

- A server started with [`serve`](@ref) stops on SIGTERM (`kill <pid>`), after
  giving requests in progress `shutdown_grace` seconds (default 10). This is
  what process managers send.
- On Julia 1.12 and later the drain on SIGTERM is `close(server; grace)` run
  by a task, so every handler can finish, whatever it waits on. **On Julia
  1.10 and 1.11 a handler that is waiting on a socket, a file, a child
  process or `Base.sleep` when the signal arrives never finishes**; there,
  drain with `close(server; grace)` before the process is signalled: see
  [Draining before the signal](@ref shutdown-drain-io).
- A server started with [`serve!`](@ref) stops when you call `close(server)` or
  `close(server; grace = seconds)`.
- Ctrl-C stops `serve` cleanly in the REPL. In a script it ends the process
  less gracefully; see [Ctrl-C](shutdown.md#Ctrl-C).

## Closing a server

`serve!` returns a [`Server`](@ref). These functions work on it:

| Call | Effect |
|---|---|
| `close(server)` | Stop accepting connections and close the open ones once their queued output is sent; WebSockets get a `1001` close. Returns at once. |
| `close(server; grace = s)` | Stop accepting, let requests in progress finish, send WebSockets a `1001` close, close what is left after `s` seconds. Returns at once. |
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
4. Each WebSocket gets its `on_shutdown` callback and a `1001` close frame,
   and is closed.
5. After `grace` seconds, whatever is still open is closed.

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
2. Facil's exit hook hands the drain to a task, which calls
   `close(server; grace = shutdown_grace)` for every open server in the
   process, each with its own `shutdown_grace`, and waits for them. With
   `verbose = true` it logs
   `Facil: signal received; closing 1 server(s), up to 5.0 s for open requests`.
3. The process ends. Its exit status is that of a process killed by SIGTERM
   (143 in a shell), not 0.

Details worth knowing:

- The drain is tied to `serve`. A process that only uses `serve!` (and waits
  some other way) exits on SIGTERM without draining. End your program with a
  `serve` call, or with `wait(server)` plus your own shutdown trigger as in the
  example above. Once one `serve` is running, every server of the process is
  drained, including those started with `serve!`.
- Code after `serve(...)` does **not** run on SIGTERM: the process exits from
  inside `serve`. Put cleanup in an `atexit` hook if you need it.
- SIGKILL cannot be handled; requests in progress are lost.

### How it works, and what differs by Julia version

Julia answers SIGTERM by interrupting its first thread, wherever it is, and
running the exit hooks there. That thread is normally the one that runs
Julia's event loop (sockets, files, child processes, `Base.sleep`, `Timer`),
so from that moment nothing waiting on the event loop wakes up again.

| | Julia 1.12 and later | Julia 1.10 and 1.11 |
|:--|:--|:--|
| Event loop during the drain | Runs. The first `serve` moves it to a thread of its own (`Base.Experimental.make_io_thread`). | Stopped. These versions have no way to move it. |
| Who drains | A Julia task, with `close(server; grace)`. With one Julia thread (`-t 1`), the exit hook itself. | The exit hook itself. |
| Handler computing | Finishes. | Finishes in most runs; not reliable on 1.10. |
| Handler in [`Facil.sleep`](@ref) | Finishes. | Not reliable on 1.10. |
| Handler waiting on a socket, file, child process, `Base.sleep`, `Timer` | Finishes. | Never returns; its client gets no response and the process exits when `shutdown_grace` runs out. |
| WebSockets | `on_shutdown`, then a `1001` close. | `1001` close; `on_shutdown` when the reactor can run it. |
| Grace period | Each server's own `shutdown_grace`. | The longest `shutdown_grace` among the servers. |

Measured on Julia 1.13 (macOS, `-t 4` and `-t 1`) with one-second handlers
and `shutdown_grace = 5`: handlers waiting in `Base.sleep`, in
`Facil.sleep` and on a child process (`run`) all answered, and the process
exited 1.0 s after the signal. On Julia 1.10 the same three requests got no
answer in two runs of three and the process exited after 5.5 s.

Moving the event loop is process-wide and happens only when `serve` is
called. Code that relied on all I/O callbacks running on Julia's first thread
(rare) no longer can.

## [Draining before the signal](@id shutdown-drain-io)

`close(server; grace)` called from ordinary code, while the process is still
running normally, drains every kind of handler on every Julia version. So on
Julia 1.10 and 1.11, or when you want the process to end with status 0, give
your service a way to be told to drain, and have whatever stops the process
use it first. An authenticated endpoint is the simplest:

```@eval
Main.example("shutdown_drain.jl")
```

```sh
$ curl http://127.0.0.1:8080/ &
$ curl -X POST -H 'X-Drain-Token: change-me' http://127.0.0.1:8080/admin/drain
draining
finished
```

After the drain request the server stops accepting, the request in
flight gets its `finished`, `wait` returns, and the program ends with exit
status 0. Under systemd, call the endpoint from `ExecStop=`; in Kubernetes,
from a `preStop` hook ([Deployment](deployment.md)). SIGTERM then arrives at a
process that is already idle or gone.

Protect the endpoint with a secret, and do not expose it through your
reverse proxy; [`client_address`](@ref) alone is not enough behind a proxy,
where every request comes from the proxy's address.

## Ctrl-C

What Ctrl-C (SIGINT) does depends on how Julia runs:

| How Julia runs | Ctrl-C |
|---|---|
| In the REPL | `serve` closes the server and returns; you are back at the prompt. |
| `julia server.jl` | Julia prints a signal report (`signal 2: Interrupt` and stack traces) and exits. Facil drains the servers first, exactly as on SIGTERM. Exit status 130. |
| `julia -e '...'`, or after `Base.exit_on_sigint(false)` | Nothing. The interrupt does not reach `serve` and the server keeps running. Stop it with SIGTERM. |

So Ctrl-C is fine while you develop. For anything automated, send SIGTERM.

## Long-lived connections

Event streams and streamed responses have no "request in progress" that
finishes by itself, so they hold a draining server open until the grace
period ends. Then they are cut. WebSockets are told to go at once:

| Connection | On `close(server)`, or during `close(server; grace)` |
|---|---|
| WebSocket | `on_shutdown` runs, the client gets a `1001` close frame, the connection closes and `on_close` runs. With `grace` this happens when the drain starts, not when it ends. |
| Event stream ([`sse`](@ref)) | Closed (with `grace`: when the grace period ends). `isopen(s)` turns `false` and [`write_event`](@ref) returns `false`, so the function should return. |
| Streamed response ([`stream`](@ref)) | Closed without the terminating chunk (with `grace`: when the grace period ends); the client sees an incomplete body. `write` throws an `IOError`. |

If you want streams to end sooner or more politely, end them yourself before
closing the server: write stream and event-stream functions as loops over
`isopen`, and give them a flag to stop on (for example a
`Threads.Atomic{Bool}` that your shutdown code sets).

Only the WebSockets of the server being closed are affected; other servers in
the process keep theirs.

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
