# [Coming from Node.js and Express](@id from-node)

This page is for readers who know Node's `http` module, Express or `ws`. It
maps what you know to Facil, points out where the model differs, and ports a
small Express app. The Node code on this page is for comparison and is not
run by this documentation's tests; the Julia code is.

## The model in one paragraph

In Node you get a request and a response *object* and call methods on the
response (`res.writeHead`, `res.end`). In Facil a handler is a function that
*returns* the response:

```@eval
Main.example("hello.jl")
```

There is no `res` to write to and no `next()`. For bodies that are produced
over time you return a [`stream`](@ref) or [`sse`](@ref) response whose
function does the writing. The other large difference is threads: Node runs
your JavaScript on one thread, while Facil's task handlers run on several
Julia threads at once, so shared state needs a lock or atomics.

## Server

| Node.js | Facil |
|---|---|
| `http.createServer(handler).listen(8080, '127.0.0.1')` | [`serve!`](@ref)`(handler, "127.0.0.1", 8080)` returns a [`Server`](@ref) at once; [`serve`](@ref) does the same and blocks |
| `server.listen(0)`, `server.address().port` | `serve!(handler, 0)`, `port(server)` |
| `server.close()` | `close(server)`; `close(server; grace = 5)` lets requests in progress finish |
| `server.on('close', ...)` | `wait(server)` blocks until it has closed |
| `server.listening` | `isopen(server)` |
| `https.createServer({cert, key}, handler)` | `serve!(handler, ...; tls = TLSConfig("cert.pem", "key.pem"))` |
| `server.setSecureContext(...)` | [`reload!`](@ref)`(server; cert, key)` |
| `server.headersTimeout`, `requestTimeout` | `header_timeout` keyword (seconds) |
| `server.keepAliveTimeout` | `timeout` keyword (seconds) |
| `server.maxHeadersCount`, `--max-http-header-size` | `max_header_size` keyword (bytes) |
| `http2`, `http.request`, `fetch` | not available: HTTP/1.1 server only, no client |

## Request

| Node.js / Express | Facil |
|---|---|
| `req.method === 'GET'` | `method(req) == Methods.GET` (or `== "GET"`) |
| `req.url` | `uri(req)`; `string(uri(req))` for the text |
| `new URL(req.url, base).pathname`, `req.path` | `path(uri(req))` (not percent-decoded) |
| `url.searchParams`, `req.query` | `query(uri(req))` is the raw string or `nothing`; parse it with `URIs.queryparams` |
| `req.headers['content-type']` | `get(headers(req), header.CONTENT_TYPE, nothing)` or `get(headers(req), "content-type", nothing)` |
| `req.headers` (lower-cased object) | `headers(req)`, a [`HeaderMap`](@ref); iterate it for `name => value` pairs |
| `req.httpVersion` | `version(req)` |
| `req.params.id` (Express) | no router built in; see the port below and [Routing](routing.md) |
| `req.body` after `express.json()` | `JSON.parse(body(req))` with a JSON package |
| `req.on('data', chunk => ...)`, `req.on('end', ...)` | by default nothing to do: `body(req)` is the whole body as a `String`. To read it as it arrives, see [Request bodies](bodies.md): `before_body = head -> Stream()` and `for chunk in body_chunks(req)` |
| `req.socket.remoteAddress`, `req.ip` | not available |
| `req.on('close', ...)` (client went away) | not available for ordinary handlers; streams see `isopen(io) == false` |

Header values are [`HeaderValue`](@ref)s, not strings. They compare equal to
strings; use `as_str(value)` when you need a `String`.

## Response

| Node.js / Express | Facil |
|---|---|
| `res.end('hello')` | return `"hello"` or `Response(StatusCodes.OK, "hello")` |
| `res.writeHead(404); res.end()` / `res.sendStatus(404)` | return `Response(StatusCodes.NOT_FOUND)` |
| `res.statusCode = 201; res.setHeader('Location', u); res.end(body)` | `Response(StatusCodes.CREATED, body; headers = [header.LOCATION => u])` |
| `res.status(400).json({error})` | `Response(StatusCodes.BAD_REQUEST, JSON.json(data); headers = [header.CONTENT_TYPE => "application/json"])` |
| `res.end(buffer)` | a `Vector{UInt8}` body |
| `res.write(chunk)` several times, then `res.end()` | return `stream(req) do io; write(io, chunk); ...; end` |
| `res.flushHeaders()` / `res.flush()` | `flush(io)` inside a stream |
| `res.write()` returning `false`, `'drain'` | `write(io, ...)` on a task blocks while the client is slow |
| `res.sendFile(path)` / `fs.createReadStream(path).pipe(res)` | return [`sendfile`](@ref)`(path)` |
| `express.static('public')` | `public_folder = "public"` keyword |
| `compression()` middleware | `compress = true` keyword |
| `res.redirect(url)` | `Response(StatusCodes.FOUND; headers = [header.LOCATION => url])` |
| `res.cookie(...)`, `req.cookies` | no helper; set and parse the `set-cookie` / `cookie` headers yourself |

Differences to keep in mind:

- `content-length` is always set by Facil. A `String` body without a
  `content-type` is sent as `text/plain; charset=utf-8`, bytes as
  `application/octet-stream`.
- `Response(404)` with only an integer throws: it could mean a status or a
  body. Write `Response(StatusCodes.NOT_FOUND)`. With a body, an integer status
  is fine: `Response(404, "not found")`.
- A response body is sent without a copy. Do not modify a `Vector{UInt8}`
  after returning it.
- An uncaught exception becomes a `500` and the server keeps running; there is
  no process crash to guard against as with an unhandled `'error'` event. See
  [Errors and logging](errors.md).

## Middleware

Express middleware calls `next()`. In Facil a middleware is a function that
takes a handler and returns a handler; it calls the inner handler and may
change what goes in or comes out.

| Express | Facil |
|---|---|
| `app.use(mw)` | `serve(mw(app), ...)` |
| `app.use(a); app.use(b)` | `serve(a(b(app)), ...)` — `a` sees the request first and the response last |
| error-handling middleware `(err, req, res, next)` | a wrapper with `try`/`catch` around the inner handler |

## An Express app, ported

Express:

```js
const express = require('express');
const app = express();
app.use(express.json());
app.use((req, res, next) => {
  res.on('finish', () => console.log(req.method, req.url, '->', res.statusCode));
  next();
});

const users = new Map([[1, 'ada'], [2, 'grace']]);

app.get('/users', (req, res) => {
  res.json([...users].map(([id, name]) => ({ id, name })));
});

app.get('/users/:id', (req, res) => {
  const name = users.get(Number(req.params.id));
  if (!name) return res.status(404).json({ error: 'no such user' });
  res.json({ id: Number(req.params.id), name });
});

app.post('/users', (req, res) => {
  if (typeof req.body.name !== 'string') return res.status(400).json({ error: 'name is required' });
  const id = Math.max(0, ...users.keys()) + 1;
  users.set(id, req.body.name);
  res.status(201).json({ id, name: req.body.name });
});

app.use((req, res) => res.status(404).json({ error: 'not found' }));
app.listen(8080);
```

Facil, with the forty lines of Express that this app relies on written out
(a `json` helper, a route table with `:param` segments, a logger):

```@eval
Main.example("node_express.jl")
```

```sh
$ curl http://127.0.0.1:8080/users/2
{"id":2,"name":"grace"}
$ curl -X POST -d '{"name":"linus"}' http://127.0.0.1:8080/users
{"id":3,"name":"linus"}
$ curl http://127.0.0.1:8080/
{"error":"not found"}
```

(The order of keys in the JSON output depends on the JSON package.)

What changed in the port, besides syntax:

- **The lock.** Task handlers run on several threads, so the `USERS`
  dictionary is guarded. In Node the single thread made that unnecessary.
- **Explicit JSON errors.** `express.json()` answers malformed JSON with a
  `400` for you; here the handler does.
- **Start-up.** Run with threads: `julia -t 4 server.jl`. With one thread,
  handlers run inline on the reactor.

## WebSockets (`ws`)

| `ws` | Facil |
|---|---|
| `new WebSocketServer({ server })` | return [`websocket`](@ref)`(req; ...)` from the handler for upgrade requests |
| `wss.on('connection', ws => ...)` | `on_open = ws -> ...` |
| `ws.on('message', (data, isBinary) => ...)` | `on_message = (ws, msg) -> ...`; `msg` is a `String` (text) or `Vector{UInt8}` (binary) |
| `ws.on('close', ...)` | `on_close = ws -> ...` |
| `ws.send(data)` | [`send`](@ref)`(ws, data)` |
| `ws.close(1000, 'bye')` | `close(ws; code = 1000, reason = "bye")` |
| `ws.readyState === WebSocket.OPEN` | `isopen(ws)` |
| `ws.bufferedAmount` | [`Facil.pending_bytes`](@ref)`(ws)` |
| `wss.clients.forEach(c => c.send(msg))` | `subscribe(ws, "room")` in `on_open`, then [`publish`](@ref)`("room", msg)` |
| `maxPayload` | `max_message_size` |
| `perMessageDeflate: true` | `deflate = true` |
| attaching properties to `ws` | `ws.data` |

By default WebSocket callbacks run on the reactor thread, much like Node's
event loop: they must not block. Pass `spawn = true` to run them on tasks. See
[WebSockets](websockets.md).

## Server-sent events

Node has no built-in helper; you write `text/event-stream` by hand. Facil has
one: return [`sse`](@ref)`(req) do s ... end` and call
[`write_event`](@ref)`(s; data, event, id)`. See [Server-sent events](sse.md).

## Timers

| Node.js | Facil |
|---|---|
| `setInterval(f, 100)` / `clearInterval(t)` | `t = every(f, 100)` (`f` returns `true` to continue) / `close(t)` |
| `setTimeout(f, 250)` | `Facil.Timer(_ -> f(), 0.25)` (seconds) |
| `await setTimeout(50)` (timers/promises) | `Facil.sleep(0.05)` in a task handler |

## Processes, cores and signals

| Node.js | Facil |
|---|---|
| one event-loop thread | one reactor thread by default; `reactors = N` for more |
| `cluster` / several processes behind a balancer | not available (no `fork`); use Julia threads (`julia -t N`) for handlers and `reactors` for I/O |
| `worker_threads` for CPU-heavy work | task handlers already run on Julia threads |
| blocking the event loop is a bug | still a bug for inline handlers and reactor callbacks; fine in task handlers |
| `async`/`await` | not needed: a task handler just blocks (`Facil.sleep`, I/O, locks) and other requests proceed |
| `process.on('SIGTERM', () => server.close())` | built into [`serve`](@ref): SIGTERM drains for `shutdown_grace` seconds |
| `process.on('SIGINT', ...)` | not catchable from a script; see [Graceful shutdown](shutdown.md#Ctrl-C) |

Two things cost more than in Node, and are worth knowing before you measure:
start-up (seconds, because Julia compiles your handler on first use) and
memory at rest. Steady-state throughput is compared row by row in
[Benchmarks](../reference/benchmarks.md).

## See also

- [Getting started](../getting-started/first-server.md) and the
  [tutorial](../getting-started/tutorial.md).
- [Handlers and concurrency](handlers.md) for the threading model.
- [Migrating from HTTP.jl](from-http-jl.md).
