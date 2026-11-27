# [Handlers and concurrency](@id handlers-guide)

This guide explains where your handler runs, what that allows it to do, and
how to choose between the two handler modes. Read it before you put a Facil
server under load: the choice between a **task handler** and an **inline
handler** is the one decision that most affects both correctness and speed.

## The threads in a Facil process

```@raw html
<figure class="facil-diagram">
<svg viewBox="0 0 760 330" width="760" role="img" aria-label="Threading model: one reactor thread runs the facil.io event loop for every connection. With inline = true the handler runs on that thread. With inline = false the request is handed to a pool of worker tasks on Julia's threads and the result is handed back. A separate timer thread wakes sleeping tasks.">
  <defs>
    <marker id="arrow-b" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z"/></marker>
  </defs>
  <rect class="box" x="10" y="130" width="96" height="60" rx="6"/>
  <text class="title" x="58" y="156" text-anchor="middle">Clients</text>
  <text class="small" x="58" y="174" text-anchor="middle">connections</text>

  <rect class="zone" x="150" y="30" width="250" height="260" rx="8"/>
  <text class="zone-label" x="162" y="50">REACTOR THREAD</text>
  <text class="small" x="162" y="66">one by default (reactors = N)</text>
  <rect class="box" x="170" y="80" width="210" height="64" rx="6"/>
  <text class="title" x="275" y="104" text-anchor="middle">event loop</text>
  <text class="small" x="275" y="122" text-anchor="middle">sockets, HTTP parsing, TLS,</text>
  <text class="small" x="275" y="136" text-anchor="middle">writes, WebSocket frames</text>
  <rect class="box" x="170" y="200" width="210" height="64" rx="6"/>
  <text class="title" x="275" y="224" text-anchor="middle">inline handler</text>
  <text class="small" x="275" y="242" text-anchor="middle">inline = true</text>
  <text class="small" x="275" y="256" text-anchor="middle">must not block</text>
  <path class="line" d="M275,144 L275,200" marker-end="url(#arrow-b)" marker-start="url(#arrow-b)"/>

  <rect class="zone" x="450" y="30" width="300" height="180" rx="8"/>
  <text class="zone-label" x="462" y="50">JULIA THREADS (julia -t N)</text>
  <rect class="box" x="470" y="66" width="125" height="52" rx="6"/>
  <text x="532" y="88" text-anchor="middle">worker task</text>
  <text class="small" x="532" y="105" text-anchor="middle">handler(req)</text>
  <rect class="box" x="610" y="66" width="125" height="52" rx="6"/>
  <text x="672" y="88" text-anchor="middle">worker task</text>
  <text class="small" x="672" y="105" text-anchor="middle">handler(req)</text>
  <text class="small" x="600" y="146" text-anchor="middle">task handlers (inline = false, the default):</text>
  <text class="small" x="600" y="162" text-anchor="middle">may block, sleep, lock, do I/O</text>
  <text class="small" x="600" y="190" text-anchor="middle">also: stream and sse bodies, timers, spawn = true</text>

  <rect class="zone" x="450" y="230" width="300" height="60" rx="8"/>
  <text class="zone-label" x="462" y="250">TIMER THREAD</text>
  <text class="small" x="462" y="270">wakes Facil.sleep, every, Facil.Timer</text>

  <path class="line" d="M106,152 L170,116" marker-end="url(#arrow-b)" marker-start="url(#arrow-b)"/>
  <path class="line" d="M380,98 L470,90" marker-end="url(#arrow-b)"/>
  <text class="small" x="424" y="84" text-anchor="middle">request</text>
  <path class="dash" d="M470,108 L380,124" marker-end="url(#arrow-b)"/>
  <text class="small" x="426" y="136" text-anchor="middle">result</text>
</svg>
<figcaption>Solid arrow: the request is handed to a worker. Dashed arrow: the result is handed back for writing.</figcaption>
</figure>
```

- **The reactor** is the thread that runs facil.io's event loop. It owns every
  socket: it accepts connections, parses requests, and writes responses.
  There is one reactor per process by default, shared by all servers in it.
- **Julia's threads** are the ones you ask for with `julia -t N`. Facil keeps
  a pool of *worker tasks* on them.
- **A timer thread** in the C library wakes tasks that called
  [`Facil.sleep`](@ref) and fires [timers](timers.md).

## Two handler modes

| | Task handler (`inline = false`, the default) | Inline handler (`inline = true`) |
|:--|:--|:--|
| Runs on | a worker task, on a Julia thread | the reactor thread |
| May block (I/O, `Facil.sleep`, locks, `wait`) | yes | **no**: every connection on that reactor waits |
| Requests handled at the same time | as many as there are waiting tasks; CPU work is limited by threads | one per reactor thread |
| Cost per request | two hand-offs between threads | none |
| Needs | `julia -t 2` or more | nothing |

```@eval
Main.example("handlers_modes.jl")
```

One process, two servers, one reactor: the first never waits and runs inline;
the second waits 50 ms per request and runs on worker tasks. Twenty concurrent
requests to the second finish in about 50 ms in total, not one second, because
a sleeping task occupies no thread.

### Task handlers

A task handler is ordinary Julia code. It can do anything a task can do:

```@eval
Main.example("handlers_where.jl")
```

- **Waiting is free.** While `/wait` sleeps, its worker serves other
  requests. You can have thousands of requests waiting on a database with a
  handful of threads.
- **CPU work occupies a thread.** While `/compute` runs, one of your `N`
  threads is busy. With `-t 4` at most four such requests make progress at
  once; the rest queue. The reactor is not affected: it keeps accepting and
  parsing, and inline servers in the same process keep answering.

How the pool works, precisely:

- When a request arrives, the reactor pauses that connection and queues a job.
  An idle worker takes it at once; if none is idle, Facil starts a task for it.
  A handler does **not** get a fresh task per request in the common case, which
  is what keeps the cost low.
- Up to `Threads.nthreads(:default) - 1` workers stay alive between requests
  (one fewer still, `nthreads(:default) - 2`, when Julia has no interactive
  thread, which is the case on Julia 1.10 and 1.11 unless you ask for one).
  One thread is always left free for tasks that yielded. With `julia -t 4` on
  Julia 1.12 or later that is three workers.
- An idle worker waits in C, not in Julia's scheduler, so an idle server uses
  no CPU.
- When the handler returns, the result is handed back to the reactor, which
  writes it and resumes the connection.

[`Facil.paused_requests()`](@ref Facil.paused_requests) tells you how many
requests are with a worker right now.

### Inline handlers

An inline handler runs inside the event loop. Nothing is handed anywhere, so
it is the fastest way to answer, and the only work per request is your code.

The price is a hard rule: **an inline handler must not block.** While it
runs, the reactor does nothing else. No other request is read, no response
written, no WebSocket message delivered. "Block" means anything that waits:

- `sleep`, `Facil.sleep`, `wait`, `fetch`, `take!` on an empty channel;
- reading from a socket, a database driver, an HTTP client;
- `lock` on a lock that another task may hold for long;
- reading a large file from a slow disk;
- more than a fraction of a millisecond of computation.

Good inline handlers: health checks, lookups in an in-memory table, anything
that builds a response from data already in memory.

!!! warning "One Julia thread means inline handlers"
    With `julia -t 1` (the default when you pass no `-t`), task handlers
    cannot run beside the reactor, so Facil runs every handler inline whatever
    `inline` says. `verbose = true` prints a note when that happens. A handler
    that sleeps for a second then stalls the whole server for a second.
    Always start a server with `-t 2` or more unless inline is what you want.

The same rule applies to the other callbacks that run on the reactor:
`before_body`, `Stream(on_chunk)`, WebSocket callbacks without `spawn = true`,
and `subscribe(f, channel)` callbacks without `spawn = true`.

## Which one to use

Start with the default. Task handlers are safe: a slow handler slows only its
own request. Switch a server to `inline = true` when both are true:

1. its handlers never block, and
2. you care about the last bit of throughput, or about CPU use and latency at
   light load.

The measured difference, from the [benchmarks](../reference/benchmarks.md)
(Apple M5 Pro, loopback, 100 connections; Node.js 22 for scale):

| Load | Inline | Task | Node.js |
|:--|:--|:--|:--|
| Tiny reply, maximum rate | 232,517 req/s (row A1) | 207,469 req/s (row A26, 4 threads) | 170,961 to 174,635 req/s |
| 10,000 req/s, p99 latency | not measured | 0.173 ms (row 31-p99) | 0.142 ms |
| 10,000 req/s, server CPU | not measured | 0.179 cores (row 31-cpu) | 0.147 cores |
| 50,000 req/s, p99 latency | 0.055 ms (row A21) | not measured | 0.061 ms |

At full load the two modes are close, because the workers never go to sleep.
At a light, steady load each hand-off wakes a sleeping thread, so a
task-handler server uses about 20% more CPU than Node and has a slightly
higher p99 (rows 31-p99 and 31-cpu are approved exceptions on the scoreboard).
Inline handlers have no hand-off and are ahead of Node at every load measured.

So:

- **Handlers that never block, light load or latency-sensitive:**
  `inline = true`.
- **Handlers that wait for anything:** the default. Do not trade correctness
  for the difference above.
- **Both kinds in one service:** two servers on two ports, as in the first
  example, or keep the default everywhere.
- **Uploads:** reading a streamed body in a task handler pays the hand-off for
  every chunk. Use [`Stream`](@ref)`(on_chunk)` when the work per chunk does
  not block; see [Request bodies and uploads](bodies.md).

## Shared state

Task handlers run in parallel on several threads. Any data that more than one
request can touch needs protection, as in any threaded program:

```@eval
Main.example("handlers_state.jl")
```

- Use `Threads.Atomic` for counters.
- Use a `ReentrantLock` around everything else, and hold it briefly.
- A `const` global that is only read (a lookup table built at start-up) needs
  nothing.

Inline handlers on a single reactor run one at a time, so they cannot race
with each other, but they can still race with timers, tasks and
`spawn = true` callbacks.

## Reactor threads

`reactors = N` runs the event loop on `N` threads, and connections are spread
over them.

```@eval
Main.example("handlers_reactors.jl")
```

- It is **process-wide and fixed by the first server**. A later `serve!` that
  asks for a different number throws an `ArgumentError`.
- It helps when the reactor itself is the bottleneck: inline handlers that do
  real CPU work. A CPU-bound inline handler measured 17,128 req/s on one
  reactor, 35,731 on two, 69,330 on four and 125,898 on eight (rows A6, A7,
  A8 and 1).
- It does not help handlers that are already as cheap as a tiny reply (rows 2
  and 3 are no faster than row A1), and it does nothing for task handlers,
  which scale with `-t` instead.
- **HTTPS needs `reactors = 1`.**
- With several reactors, inline handlers do run in parallel: protect shared
  state.

## Garbage collection

Julia's garbage collector stops every thread while it runs, the reactor
included. Requests that arrive during a collection wait for it. Short
collections are invisible; long ones are the slowest requests you will see.
[Performance tuning](performance.md) shows how to keep them short.

## A client that goes away

A handler is not interrupted when its client disconnects: it runs to the end
and its result is discarded. A task handler can watch for it and stop early:
[`isconnected`](@ref)`(req)` turns `false` within about half a second of the
client closing its connection, and [`on_disconnect`](@ref)`(f, req)` runs `f`
on a task of its own when that happens. Inline handlers cannot: the reactor
that runs them is not watching the connection meanwhile. Streamed responses
are different again: [`ResponseStream`](@ref) reports a gone client through
`isopen` and by throwing from `write`.

A client may also finish sending and keep listening: it writes its request and
shuts down its side of the connection, as `nc`, some health checkers and some
proxies do. Facil reads and answers everything that arrived before the end of
the client's stream, pipelined requests included, and then closes the
connection. A client that writes a request and closes completely at once is
read too: the handler runs and its response is dropped. Event streams and
WebSockets treat the end of the client's stream as the client leaving, and so
does a response streamed with `spawn = true` on a server with inline handlers.

## See also

- [`serve!`](@ref) for the `inline` and `reactors` keywords.
- [Request bodies and uploads](bodies.md) for `Stream(on_chunk)`.
- [Timers](timers.md) for `Facil.sleep` in handlers.
- [Performance tuning](performance.md) and [Deployment](deployment.md) for
  thread counts in production.
- [Benchmarks](../reference/benchmarks.md) for every number quoted here.
