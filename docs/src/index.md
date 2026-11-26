# Facil.jl

Facil is an HTTP server for Julia. You write a function that takes a request
and returns a response; Facil does the rest: HTTP/1.1, HTTPS, WebSockets,
server-sent events, streaming, static files and compression.

```@eval
Main.example("hello.jl")
```

```sh
$ julia -t 4 hello.jl &
$ curl http://127.0.0.1:8080/
hello
```

Under the hood, the sockets, the event loop and the HTTP parser are
[facil.io](https://github.com/boazsegev/facil.io), a C library. The request
and response types are [HttpTypes](api/httptypes/index.md), a pure-Julia port
of the Rust [`http`](https://github.com/hyperium/http) crate, which Facil
re-exports. Your handlers are plain Julia and run on Julia's threads.

## Where to start

**New to Facil?** Follow the getting-started pages in order. You will have a
tested JSON API running in about fifteen minutes.

1. [Install](getting-started/install.md)
2. [Your first server](getting-started/first-server.md): the request →
   handler → response model
3. [Tutorial: a JSON API](getting-started/tutorial.md): routing, JSON, errors,
   a test
4. [Deployment](guide/deployment.md): from a script to a service

**Coming from another server?** These pages map what you know onto Facil,
side by side.

- [Coming from HTTP.jl](guide/from-http-jl.md)
- [Coming from Node.js and Express](guide/from-node.md)

**Looking something up?** The reference has every function with its exact
signature, arguments, defaults, errors and a tested example.

- [API reference](api/index.md): [`serve`](@ref), [`stream`](@ref),
  [`websocket`](@ref), [`Request`](@ref), [`Response`](@ref), [`HeaderMap`](@ref) and the rest
- [Configuration](reference/configuration.md): every `serve` keyword in one table
- [FAQ and troubleshooting](reference/faq.md): by symptom

## Guides

Each guide covers one task with complete programs you can copy.

| Handling requests | Sending responses | Real-time |
|:--|:--|:--|
| [Handlers and concurrency](guide/handlers.md) | [Sending responses](guide/responses.md) | [WebSockets](guide/websockets.md) |
| [Reading requests](guide/requests.md) | [Streaming responses](guide/streaming.md) | [Pub/sub](guide/pubsub.md) |
| [Request bodies and uploads](guide/bodies.md) | [Server-sent events](guide/sse.md) | [Timers](guide/timers.md) |
| [Routing](guide/routing.md) | [Static files](guide/static.md) | |
| [JSON](guide/json.md) | [Compression](guide/compression.md) | |

| Running in production | |
|:--|:--|
| [HTTPS](guide/tls.md) | [Deployment](guide/deployment.md) |
| [Shutdown and signals](guide/shutdown.md) | [Performance tuning](guide/performance.md) |
| [Errors and logging](guide/errors.md) | [Security](guide/security.md) |
| [Testing](guide/testing.md) | |

## What to know before you choose Facil

- **HTTP/1.1 only.** No HTTP/2 or HTTP/3; put a proxy in front if you need
  them.
- **Linux and macOS.** On Windows, use WSL2
  ([Platform support](reference/platforms.md)).
- **Not registered yet.** Installing needs a clone and a C compiler for now.
- **A server, not a framework.** There is no router, no middleware stack and
  no HTTP client. Handlers are functions; the guides show how far that goes.
- **Fast, with known exceptions.** Facil is at or above Node.js on 76 of the
  100 rows of its [benchmark scoreboard](reference/benchmarks.md) and within
  4% on 5 more; start-up time, memory and garbage-collection pauses are where
  it is behind.

[Limits](reference/limits.md) is the full, plain list.

## About these docs

Every example on this site is a program in
[`docs/examples`](https://github.com/aryan-juliahub/Facil.jl/tree/main/docs/examples)
that the documentation build starts on a free port and checks with a client,
or a doctest that the build runs. If an example here does not work for you,
that is a bug: please
[report it](https://github.com/aryan-juliahub/Facil.jl/issues).
The [changelog](reference/changelog.md) lists what changed.
