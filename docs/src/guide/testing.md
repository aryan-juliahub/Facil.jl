# [Testing a Facil app](@id testing-guide)

This page shows two ways to test a Facil application with Julia's `Test`
standard library: calling the handler directly with a request you build, and
running a real server on a free port and talking to it over HTTP. Use the first
for most tests and the second for a few end-to-end checks.

## Structure your app for testing

Write the handler as a named function, and keep the `serve` call out of the
code your tests load: put it in a `main()` function or a separate script.
Tests can then load the application without starting a server. The
application used on this page:

```@eval
Main.example("testing_app.jl", "app")
```

## Unit tests: call the handler

A handler takes a [`Request`](@ref) and returns a [`Response`](@ref). Build
the first, inspect the second. No server runs, so these tests are fast and
cannot fail on a busy port.

```@eval
Main.example("testing_app.jl", "unit")
```

Building requests:

- `Request(method, target, body; headers = [...])`. The method may be a
  constant (`Methods.POST`) or a string (`"POST"`); the target is a string
  such as `"/items?page=2"`.
- Pass `""` as the body of requests that have none. The server always hands
  handlers a `Request{String}` whose body is `""` when the client sent none;
  `Request(Methods.GET, "/health")` without a body argument makes a
  `Request{Nothing}` instead, and `isempty(body(req))` would throw.
- Headers are `name => value` pairs. Names are case-insensitive.

Inspecting responses:

- `status(res)` compares equal to both `StatusCodes.OK` and `200`.
- `body(res)` is whatever the handler put in: a `String`, a `Vector{UInt8}` or
  `nothing`.
- `headers(res)[header.CONTENT_TYPE]` (or `"content-type"`) is the value; it
  compares equal to a string. Use `get(headers(res), name, nothing)` when the
  header may be absent.
- A handler may return a plain `String`. If yours does, test for that, or
  normalise with `res isa Response ? res : Response(StatusCodes.OK, res)`.

What unit tests do not cover is everything the server adds: the default
`content-type`, `content-length`, limits, `before_body`, compression, and the
bodies of [`stream`](@ref), [`sse`](@ref) and [`sendfile`](@ref) responses
(their `body(res)` is an internal object, not the bytes). Test those end to
end.

## End-to-end tests: a real server

Start the app with [`serve!`](@ref) on port `0`, which picks a free port; ask
the server which one with `port(server)`; close it in a `finally` block so a
failing test does not leave it running.

Any HTTP client works. `Downloads` ships with Julia, so it needs no extra
dependency; a small wrapper makes it convenient:

```@eval
Main.example("testing_app.jl", "client")
```

!!! warning "`import Downloads`, not `using Downloads`"
    `Downloads` exports a type called `Response`, and so does Facil. With
    `using Facil, Downloads` in one module, the name `Response` is ambiguous
    and using it throws an `UndefVarError`. Write `import Downloads` and
    qualify its functions (`Downloads.request`).

```@eval
Main.example("testing_app.jl", "e2e")
```

The whole file runs as a test script:

```sh
$ julia -t 4 --project testing_app.jl
Test Summary: | Pass  Total
handler       |    7      7
Test Summary: | Pass  Total
server        |    6      6
```

### Tips

- **Never use a fixed port in tests.** Port 0 lets parallel test runs and CI
  machines coexist. `serve!` throws a `SystemError` if a fixed port is taken.
- **Close and wait.** `close(server)` returns at once; `wait(server)` blocks
  until the port is released (up to about a second). Skip the `wait` when
  nothing after it depends on the port.
- **One reactor per process.** All servers in a test process share it, and the
  first server fixes `reactors`. A test that needs a different `reactors`
  value must run in its own process.
- **Threads.** Run tests with several threads
  (`julia -t 4 --project -e 'using Pkg; Pkg.test()'`) if your app relies on
  task handlers. With one thread every handler runs inline, and a handler
  that waits for another request to the same server would deadlock.
- **Inline servers.** For `inline = true` apps, start the test server with
  `inline = true` as well, so blocking mistakes show up as stalls in tests.
- **Slow first request.** The first request compiles your handler. Give
  time-outs in CI some slack, or make one warm-up request before timing
  anything.
- **Asserting on logs.** Facil writes errors to file descriptor 2, not through
  `Logging`, so `@test_logs` does not see them. Test the response instead.

## Testing WebSocket code

Julia's standard library has no WebSocket client, and Facil does not include
one. Two approaches work:

1. Keep what a message does in a function of plain values and test that
   function directly. The callbacks become one-liners that need no test.
2. For end-to-end tests, add a WebSocket client package to your test
   dependencies and connect to `ws://127.0.0.1:$(port(server))/`.

The first approach:

```@eval
Main.example("testing_ws.jl", "logic")
```

```@eval
Main.example("testing_ws.jl", "tests")
```

A [`WebSocket`](@ref) cannot be constructed in a test, which is why the logic
takes the history vector rather than `ws`.

## See also

- [Errors and logging](errors.md).
- [Tutorial](../getting-started/tutorial.md), which tests a JSON API.
- API: [`serve!`](@ref), [`Server`](@ref), [`Request`](@ref), [`Response`](@ref).
