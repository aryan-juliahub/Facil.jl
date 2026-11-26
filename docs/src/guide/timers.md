# [Timers and `Facil.sleep`](@id timers-guide)

This page shows how to wait inside a handler and how to run code later or
repeatedly: [`Facil.sleep`](@ref), [`Facil.Timer`](@ref) and [`every`](@ref).
All three are timed by one C timer thread that Facil starts on first use.

## Why not `Base.sleep`

`Base.sleep` is built on the libuv event loop and is coarse for short waits.
Measured on macOS with Julia 1.13 (mean of 50 calls):

| Call | `Base.sleep` | `Facil.sleep` |
|---|---|---|
| `sleep(0.001)` | 2.5 ms | 1.02 ms |
| `sleep(0.01)` | 12.9 ms | 10.03 ms |

`Facil.sleep(seconds)` blocks the current task for `seconds` and overshoots by
tens of microseconds. Other tasks run meanwhile. Neither `sleep` nor `Timer` is
exported, because they would clash with the functions of the same name in
`Base`: write `Facil.sleep` and `Facil.Timer`.

Details:

- `Facil.sleep(0)` yields to other tasks and returns.
- A negative time is treated as 0; `NaN` throws an `ArgumentError`.
- It works on any task, with or without a server running.

!!! warning "Not in inline handlers"
    On a reactor thread (an inline handler, a default WebSocket callback, a
    `subscribe(f, channel)` callback) `Facil.sleep` blocks that thread: every
    connection it serves stalls for the duration. Wait only in task handlers
    and in callbacks that run on tasks. See
    [Handlers and concurrency](handlers.md).

## Repeat with `every`

`every(f, ms)` calls `f()` every `ms` milliseconds, first after `ms`. It stops
when `f` returns `false`, so end the function with `true` to keep going (any
value other than `false` continues). It returns a [`Facil.Timer`](@ref), which
you can `close`.

## One-shot and general timers

`Facil.Timer(callback, delay; interval = 0)` calls `callback(timer)` after
`delay` seconds, and then every `interval` seconds if `interval` is positive.
Note the units: **seconds** for `Facil.Timer` and `Facil.sleep`,
**milliseconds** for `every`.

- `close(timer)` stops it. A callback that is already running finishes; none
  starts afterwards. Closing twice is fine.
- `isopen(timer)` is `false` once the timer was closed or has finished (a
  one-shot timer after its call).
- The callback may close its own timer.

This server uses all three: a ticker, a one-shot timer and a wait in the
handler.

```@eval
Main.example("timers_ticks.jl")
```

## Where callbacks run

Timer callbacks run on a Julia task of the default thread pool (not on the
reactor and not on the timer thread), so they may block, take locks and do I/O.
Each timer has one task: its callback never overlaps with itself. Different
timers run in parallel on different threads, so guard shared state (the example
uses atomics).

A timer keeps running whether or not a server exists, and does not keep the
process alive: when your script ends, the process exits with timers still open.

## Late ticks are skipped

If a callback takes longer than the interval, the ticks that fell due while it
ran are skipped, not queued. The next call happens at the next multiple of the
interval. A 50 ms timer whose callback once takes 220 ms loses four ticks and
then continues on its original schedule. Timers do not drift: the schedule is
`start + n × interval`, however long the callbacks take.

## Errors stop a timer

If the callback throws, the error is logged to stderr and the timer is closed.
It does not run again. To keep a timer alive, catch errors inside the callback:

```@eval
Main.example("timers_errors.jl")
```

The process behind the first timer prints, once:

```text
Facil: uncaught error in a timer callback: tick 3 failed
```

followed by the stack trace. See [Errors and logging](errors.md) for how
repeated errors are grouped.

## Common uses

- Periodic work next to a server: refresh a cache, publish a heartbeat with
  [`publish`](@ref), check a certificate file (see [TLS](tls.md#Replace-a-certificate-without-restarting)).
- A delayed action: `Facil.Timer(_ -> close(server; grace = 5), 0.5)`.
- Keep-alive comments on an event stream (see [Server-sent events](sse.md)).

## See also

- [Handlers and concurrency](handlers.md).
- [Graceful shutdown](shutdown.md).
- API: [`Facil.sleep`](@ref), [`Facil.Timer`](@ref), [`every`](@ref).
