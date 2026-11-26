# [Security notes](@id security-guide)

This page lists what Facil does to protect a server that faces untrusted
clients, which settings you should review, and what it leaves to you. It is a
checklist, not a guarantee: read it before you put a server on the internet.

## What Facil is, and is not

Facil is an HTTP server library. It parses requests strictly, enforces size and
time limits, and speaks TLS. It has **no** authentication, sessions, cookies
helpers, CORS, CSRF protection, rate limiting or request filtering. Those are
yours to write (examples below) or to put in a reverse proxy.

Facil has not had an independent security audit. The C core is facil.io 0.7
with this project's patches (see `deps/patches` in the repository).

## Limits on requests

Every limit has a default; every one can be changed per server with a keyword
of [`serve`](@ref) / [`serve!`](@ref). The complete table is in
[Configuration](../reference/configuration.md).

| Threat | Setting | Default | What the client gets |
|---|---|---|---|
| Huge request head | `max_header_size` | 32 KiB | `431` |
| Huge body | `max_body_size` | 50 MiB | `413`, before the body is read when the length is declared |
| Bodies filling memory | `body_in_memory` | 16 MiB | `413` for `Buffer()` bodies above it |
| Head sent a few bytes at a time (slowloris) | `header_timeout` | 30 s | `408`, connection closed |
| Idle connections piling up | `timeout` | 40 s | connection closed |
| Client that requests but never reads | `max_pending_output` | 16 MiB | disconnected after about 3 s without reading |
| Huge WebSocket message | `max_message_size` of [`websocket`](@ref) | 1 MiB | close code `1009` |

The defaults suit a general API. Tighten them to what your application needs;
a JSON API rarely needs 50 MiB bodies. This server does that, and decides per
request what may be uploaded:

```@eval
Main.example("security_limits.jl")
```

Points to know:

- **`before_body` runs before any of the body is read.** It is the place to
  refuse uploads by path, method, content type, declared length or missing
  credentials. [`Reject`](@ref)`(status)` answers and closes the connection
  without reading the body, and without sending `100 Continue`.
- **Chunked bodies have no declared length** (`head.content_length == -1`,
  [`Facil.ischunked`](@ref)). `max_body_size` and `body_in_memory` still stop
  them, but only once that many bytes have arrived. Refuse them up front, as
  above, if you do not need them.
- **`header_timeout` is checked when bytes arrive.** A client that trickles its
  request head gets the `408` once the time has passed. A client that connects
  and sends nothing more at all is closed by the idle `timeout` instead (40
  seconds by default), without a response. Lower `timeout` as well if silent
  connections are a concern.
- **`header_timeout` is process-wide.** The value of the most recently started
  server applies to all servers.
- **There is no limit on the number of connections** other than the process's
  file-descriptor limit (`ulimit -n`). Each idle connection costs little
  memory, but put a connection limit in your proxy or firewall if you need one.
- **A handler is not cancelled when its client disconnects** (see
  [Errors and logging](errors.md#A-client-that-goes-away)). An endpoint that
  starts expensive work on every request can be made to do that work with
  cheap, abandoned requests. Bound such work yourself.

## Request parsing

- Requests with both `content-length` and `transfer-encoding`, a negative or
  non-numeric `content-length`, or malformed chunk sizes are refused with
  `400`. This closes the usual request-smuggling gaps between a proxy and the
  server.
- A request without a `Host` header gets a `400`, also on HTTP/1.0.
- The method, target and header names are validated again by HttpTypes when
  the request is built; what fails gets a `400` and never reaches your handler.
- **Paths and queries are not percent-decoded and not normalised.**
  `path(uri(req))` is what the client sent: `/a/../b`, `/a%2Fb` and `//a`
  arrive as written. Compare against exact strings, and decode and check
  segments yourself before using any of it to build a file path, a database
  key or a URL.
- Header values may contain any bytes except control characters. Treat them as
  untrusted input.

## Responses

- A header value with a line break cannot be built: `HeaderValue` (and so
  `Response(...; headers = [...])`) throws `InvalidHeaderValue`. Passing user
  input into a response header therefore cannot split the response; the
  request fails with a `500` instead. Validate first if you want a better
  answer.
- The `500` for an uncaught error has a fixed body. Exception messages and
  stack traces go to stderr only.
- Facil sets no security headers (`strict-transport-security`,
  `content-security-policy`, `x-content-type-options`, ...). Add the ones you
  need in a wrapper.

## Static files

With `public_folder`, Facil serves files below that directory.

- A request path that contains `..` is never served from the folder. It is
  passed to your handler instead, with the path as sent, so your handler must
  not map paths to files naively either.
- A path with an encoded NUL (`%00`) gets a `400`.
- **Symbolic links are followed** by default, including links that point
  outside the folder. `symlinks = :inside` refuses files that resolve outside
  it.
- Files whose names start with a dot are served by default. Keep `.env`,
  `.git` and similar out of the folder, or pass `dotfiles = :deny`.
- [`sendfile`](@ref)`(path)` sends exactly the path you give it. If any part of
  that path comes from the request, check it: reject `..`, absolute paths and
  NUL bytes, or look the name up in a list of known files.

## TLS

- Serve HTTPS with a [`TLSConfig`](@ref), or terminate TLS in a proxy and keep
  Facil on a loopback or private address. See [TLS](tls.md).
- `min_version` defaults to TLS 1.2. Do not lower it.
- Protect private keys with file permissions. A `TLSConfig` holds the key
  text in memory for the life of the object.
- Client certificates (`client_ca`, `require_client_cert`) authenticate
  machines at the connection level; the handler cannot see who connected.

## Secrets in logs

`show` and `repr` of a request print every header, including `authorization`
and `cookie`. Do not log whole requests.

HttpTypes can mark a header value as sensitive, which hides it from `show`:

```@example
using Facil
token = set_sensitive(HeaderValue("Bearer s3cret"), true)
(token, is_sensitive(token))
```

The mark is not applied to incoming requests automatically, and `print`,
`string` and `as_str` still give the real bytes. It protects values you mark
yourself from ending up in `show` output; it is not a general defence.

## Authentication and CORS

Neither is built in. Both fit in a wrapper around your handler. This example
requires a bearer token on every request and answers CORS preflight requests
for one allowed origin:

```@eval
Main.example("security_wrappers.jl")
```

```sh
$ curl -i http://127.0.0.1:8080/
HTTP/1.1 401 Unauthorized
...
$ curl -H 'Authorization: Bearer change-me' http://127.0.0.1:8080/
the secret data
```

Compare secrets in constant time, as `same_secret` does; `==` on strings stops
at the first difference and leaks how much of a guess was right. Read real
tokens from the environment or a secret store, never from source code.

## Behind a reverse proxy

Facil does not interpret `x-forwarded-for`, `x-forwarded-proto`, `forwarded`
or the PROXY protocol, and it does not expose the address of the connected
client at all. Consequences:

- If you need the client's address (for logs or rate limits), have your proxy
  set a header and read it in the handler. Trust that header only if the
  server is reachable through the proxy alone: bind to `127.0.0.1` (the
  default host) or a private address, not `0.0.0.0`.
- Have the proxy strip or overwrite forwarding headers sent by clients.
- Per-client rate limiting belongs in the proxy, since Facil cannot tell
  clients apart.
- Make the proxy's body and header limits no larger than Facil's, so that
  oversized requests are refused at the edge.

## Process hygiene

- Run as an unprivileged user. Listen on a high port and let the proxy or a
  socket-forwarding rule own 80 and 443.
- The default host is `127.0.0.1`. A server is reachable from other machines
  only when you pass another address such as `"0.0.0.0"` or `"::"`.
- Handlers run in the server's process with all its privileges and share its
  memory across threads. Guard shared state with locks or atomics.

## See also

- [Limits](../reference/limits.md) and [Configuration](../reference/configuration.md).
- [Request bodies](bodies.md) for `before_body`.
- [TLS](tls.md), [Deployment](deployment.md).
