# [Tutorial: a JSON API](@id tutorial)

This tutorial builds a small but complete web service in about ten minutes: a
notes API with routing, path and query parameters, JSON in and out, proper
error responses and a test. At the end you run it and call it with `curl`.

You need Facil installed ([Install](install.md)) and one more package for
JSON:

```sh
julia --project=. -e 'using Pkg; Pkg.add("JSON")'
```

The finished program is one file, `notes.jl`. Each section below adds a part
of it; the whole file is at the [end of the page](@ref tutorial-whole-file).

## The API

| Request | Does | Success |
|:--|:--|:--|
| `GET /notes` | list notes, optionally filtered with `?q=text` | `200`, a JSON array |
| `POST /notes` | create a note from a JSON object with `title` and `text` | `201`, the note, and a `location` header |
| `GET /notes/{id}` | fetch one note | `200`, the note |
| `DELETE /notes/{id}` | delete a note | `204`, no body |
| `GET /health` | liveness check for a load balancer | `200`, `ok` |

Errors are JSON too: `{"error": "..."}` with a fitting status.

## 1. Storage

The notes live in memory, in a `Dict`.

```@eval
Main.example("tutorial_notes.jl", "storage")
```

The lock matters. Facil runs handlers on several threads at once (that is
what `julia -t 4` gives you), so two requests can touch `NOTES` at the same
moment. Every access to shared state needs a lock, exactly as in any threaded
Julia program.

## 2. Two helpers

Every response of this API is JSON, so wrap that once:

```@eval
Main.example("tutorial_notes.jl", "helpers")
```

`JSON.json` turns a struct, a named tuple, a `Dict` or a vector into JSON
text. Facil does not set `content-type: application/json` for you, because a
`String` body could be anything; the helper adds it.

## 3. Listing, with a query parameter

```@eval
Main.example("tutorial_notes.jl", "list")
```

[`query_param`](@ref)`(req, "q")` splits the query string, decodes it (`+`
and `%20` become spaces) and returns the first value of `q`, or `default`
when the query has none. [`query_params`](@ref) returns every pair, in order.

Note the shape of the function: take the lock, copy out what you need,
release it, and only then build the response. Hold a lock for as short a time
as you can.

## 4. Creating, with validation

```@eval
Main.example("tutorial_notes.jl", "create")
```

`body(req)` is the request body as a `String`. The client can send anything,
so each step that can fail returns an error response early:

- `400 Bad Request` when the body is not JSON at all;
- `422 Unprocessable Entity` when it is JSON but a field is missing or has
  the wrong type.

Without the `try`, bad JSON would throw inside the handler and the client
would get a `500`, which wrongly says the server is at fault.

A successful create answers `201 Created` with a `location` header that
points to the new note.

## 5. One note: path parameters

```@eval
Main.example("tutorial_notes.jl", "one")
```

These take the note id as an argument. The router extracts it from the path.

## 6. Routing

Facil has no router. A handler looks at the method and the path and decides:

```@eval
Main.example("tutorial_notes.jl", "router")
```

- `method(req)` compares with the constants in `Methods`.
- `path(uri(req))` is the path without the query string.
- A regular expression captures the path parameter. `\d+` only matches
  digits, so `parse(Int, ...)` cannot fail.
- A known path with the wrong method gets `405 Method Not Allowed` and an
  `allow` header, which is what HTTP asks for. An unknown path gets `404`.

For larger applications, [Routing](../guide/routing.md) shows a small
table-driven router you can copy.

## 7. Serving

```@eval
Main.example("tutorial_notes.jl", "main")
```

`max_body_size` caps request bodies at 64 KiB; a larger one gets
`413 Payload Too Large` before your handler runs. A notes API has no reason
to accept the default 50 MiB.

The `if` makes the file do two jobs: run as a program
(`julia notes.jl` serves), and be `include`d by a test without starting a
server.

## 8. Run it

```sh
julia -t 4 --project=. notes.jl
```

In another terminal:

```sh
$ curl -i -X POST http://127.0.0.1:8080/notes -d '{"title": "Buy milk", "text": "2 litres"}'
HTTP/1.1 201 Created
content-type: application/json
location: /notes/1
content-length: 45

{"id":1,"title":"Buy milk","text":"2 litres"}

$ curl 'http://127.0.0.1:8080/notes?q=MILK'
[{"id":1,"title":"Buy milk","text":"2 litres"}]

$ curl -X POST http://127.0.0.1:8080/notes -d '{"text": "x"}'
{"error":"title is required"}

$ curl http://127.0.0.1:8080/notes/7
{"error":"no note 7"}

$ curl -i -X PUT http://127.0.0.1:8080/notes/1
HTTP/1.1 405 Method Not Allowed
allow: GET, DELETE
...

$ curl -X DELETE -i http://127.0.0.1:8080/notes/1
HTTP/1.1 204 No Content
```

(The `-i` output is shortened here: Facil also sends `connection`, `date`
and `last-modified` headers.)

The first request after start-up takes a few hundred milliseconds while Julia
compiles your handler; later ones take microseconds. [Deployment](../guide/deployment.md)
shows how to remove that delay.

## 9. Test it

Save this as `test_notes.jl` next to `notes.jl`:

```@eval
Main.example("tutorial_notes_test.jl")
```

```sh
$ julia -t 4 --project=. test_notes.jl
Test Summary: | Pass  Total  Time
notes API     |   13     13  0.7s
```

The pattern is the same for any Facil application:

- `serve!(app, 0)` starts the real server on a free port, and
  `port(server)` tells you which. Never hard-code a port in a test.
- A real HTTP client makes the requests. `Downloads` ships with Julia, so the
  test needs no extra dependency. Write `import Downloads`, not
  `using Downloads`: Downloads exports a `Response` type of its own, which
  would clash with Facil's.
- `close(server)` in a `finally` block stops the server even when a test
  fails.

[Testing](../guide/testing.md) has more, including calling handlers directly
without a server.

## Where to go from here

You now have every piece of a typical JSON service. To take it to production:

- [Deployment](../guide/deployment.md): threads, a systemd unit, a container
  image, a reverse proxy, health checks, faster start-up.
- [Shutdown and signals](../guide/shutdown.md): finish requests in flight
  when the process is told to stop.
- [Security](../guide/security.md): limits, timeouts and HTTPS.
- [Errors and logging](../guide/errors.md): an access log and your own error
  pages.

## [The whole file](@id tutorial-whole-file)

```@eval
Main.example("tutorial_notes.jl")
```
