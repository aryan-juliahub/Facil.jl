# [Configuration](@id configuration-reference)

This page lists every setting of a Facil server in one place: the keywords of
[`serve`](@ref) and [`serve!`](@ref), the process-wide settings, the options
of the response functions, and the Julia flags and environment variables that
matter. Each entry links to the guide that explains it.

## `serve` and `serve!` keywords

`serve(handler, host = "127.0.0.1", port = 8080; keywords...)`. Both functions
take the same keywords. Here they all are at their defaults; the
documentation build checks this program against the defaults in the code:

```@eval
Main.example("config_defaults.jl")
```

### Handlers and threads

| Keyword | Type | Default | Effect |
|:--|:--|:--|:--|
| `inline` | `Bool` | `false` | `false`: handlers run on worker tasks and may block. `true`: handlers run on the reactor thread and must not block. Forced to `true` when Julia has one thread. [Guide](../guide/handlers.md) |
| `reactors` | `Integer` ≥ 1 | `1` | Number of reactor (event-loop) threads. **Process-wide**, fixed by the first server; a different value later throws. Must be `1` with `tls`. [Guide](../guide/handlers.md#Reactor-threads) |

### Limits and timeouts

| Keyword | Type | Default | Effect |
|:--|:--|:--|:--|
| `max_header_size` | `Integer` ≥ 1024 | `32768` (32 KiB) | Largest request head in bytes. Larger: `431`, connection closed. |
| `max_body_size` | `Integer` ≥ 0 | `52428800` (50 MiB) | Largest request body in bytes, however it is received. Larger: `413`, connection closed. |
| `body_in_memory` | `Integer` ≥ 0 | `16777216` (16 MiB) | Largest body `Buffer()` holds in memory. Larger: `413`. Does not apply to `Stream()` and `Spool()`. |
| `timeout` | `Integer`, 1 to 255 | `40` | Seconds an idle connection is kept open. |
| `header_timeout` | `Integer`, 0 to 3600 | `30` | Seconds a client has to send a complete request head; a client still sending after that gets `408`. `0` disables. **Process-wide**: the last server started sets it. |
| `max_pending_output` | `Integer` ≥ 0 | `16777216` (16 MiB) | A client with more unsent response bytes than this that stops reading for about 3 seconds is disconnected. `0` disables. |

See [Limits](limits.md) and [Security](../guide/security.md).

### Request bodies

| Keyword | Type | Default | Effect |
|:--|:--|:--|:--|
| `before_body` | function `RequestHead -> Buffer`, `Stream`, `Spool` or `Reject` | `head -> Buffer()` | Called on the reactor thread for each request that has a body, before the body is read; chooses where the body goes. [Guide](../guide/bodies.md) |

### Responses

| Keyword | Type | Default | Effect |
|:--|:--|:--|:--|
| `compress` | `Bool` or [`CompressOptions`](@ref) | `false` | Compress responses with zstd, brotli or gzip according to `Accept-Encoding`. `true` is `CompressOptions()`. [Guide](../guide/compression.md) |
| `public_folder` | `Nothing` or `AbstractString` | `nothing` | A directory served for `GET`, `HEAD` and `OPTIONS` before the handler is called; requests that match no file reach the handler. [Guide](../guide/static.md) |
| `dotfiles` | `:serve` or `:deny` | `:serve` | `:deny`: `public_folder` does not serve a path with a part that starts with a dot (`.env`, `.git/config`); the request reaches the handler. [Guide](../guide/static.md#What-is-never-served,-and-what-you-can-turn-off) |
| `symlinks` | `:follow` or `:inside` | `:follow` | `:inside`: `public_folder` does not serve a file that resolves to a place outside the folder; the request reaches the handler. [Guide](../guide/static.md#What-is-never-served,-and-what-you-can-turn-off) |

### HTTPS

| Keyword | Type | Default | Effect |
|:--|:--|:--|:--|
| `tls` | `Nothing` or [`TLSConfig`](@ref) | `nothing` | Serve HTTPS with these certificates and settings. Needs `reactors = 1`. [Guide](../guide/tls.md) |

### Operation

| Keyword | Type | Default | Effect |
|:--|:--|:--|:--|
| `shutdown_grace` | `Real` ≥ 0 | `10` | Seconds that requests in flight get to finish when a process running `serve` receives SIGTERM (or Ctrl-C in a script). [Guide](../guide/shutdown.md) |
| `verbose` | `Bool` | `false` | Write a start-up line (address, threads, limits) and a line per request rejected by `before_body` or `body_in_memory` to stderr. [Guide](../guide/errors.md) |
| `gc_headroom` | `Integer` ≥ 0 | `0` | Bytes of heap headroom; calls [`Facil.gc_headroom!`](@ref). **Process-wide**, only grows. [Guide](../guide/performance.md) |

An out-of-range value throws `ArgumentError` when the server starts. So does
an unknown keyword; the message names the closest valid keyword and lists all
of them.

## Positional arguments

| Argument | Type | Default | Notes |
|:--|:--|:--|:--|
| `handler` | any callable | required | `handler(req::Request{String})`; first argument, so `do` blocks work |
| `host` | `AbstractString` | `"127.0.0.1"` | `"0.0.0.0"` for all IPv4 interfaces, `"::"` for IPv6; host names are resolved |
| `port` | `Integer`, 0 to 65535 | `8080` | `0` picks a free port; read it with `port(server)` |

`serve(handler, port)` is short for `serve(handler, "127.0.0.1", port)`.

## Process-wide settings

These apply to every server in the process. Set them before serving.

| Call | Default state | Effect |
|:--|:--|:--|
| [`Facil.slow_subscribers!`](@ref)`(; limit, policy)` | no limit | What a pub/sub broadcast does with a WebSocket client that is not reading |
| [`Facil.websocket_compressor!`](@ref)`(codec)` | `:zlibng` | Codec for WebSocket permessage-deflate |
| [`Facil.register_mime!`](@ref)`(ext, type)` | built-in table | `content-type` for a file extension |
| [`Facil.gc_headroom!`](@ref)`(bytes)` | `0` | Heap headroom for the garbage collector |

## Per-response options

The functions that build special responses take their own keywords,
documented with each function:

| Function | Keywords |
|:--|:--|
| [`stream`](@ref) | `status`, `headers`, `compress`, `level`, `spawn`, `high_water` |
| [`sse`](@ref) | `headers`, `high_water` |
| [`sendfile`](@ref) | `status`, `headers` |
| [`websocket`](@ref) | `on_open`, `on_message`, `on_close`, `on_ready`, `on_shutdown`, `max_message_size`, `deflate`, `utf8_check`, `spawn`, `borrow`, `subprotocol` |
| [`Stream`](@ref) | `on_chunk`, `high_water` |
| [`CompressOptions`](@ref) | `prefer`, `gzip`, `br`, `zstd`, `min_size`, `compressible` |
| [`TLSConfig`](@ref) | `password`, `sni`, `min_version`, `max_version`, `ciphers`, `ciphersuites`, `prefer_server_ciphers`, `client_ca`, `require_client_cert` |

## Julia flags and environment variables

| Setting | Effect |
|:--|:--|
| `julia -t N` or `JULIA_NUM_THREADS=N` | Julia threads for task handlers. With `1`, handlers run inline. |
| `julia --gcthreads=N` or `JULIA_NUM_GC_THREADS=N` | Garbage-collector threads; shortens pauses on `-t 1` servers. |
| `julia -J image.so` | Start from a system image; see [Deployment](../guide/deployment.md). |
| `FACIL_VERBOSE=1` | Raise facil.io's own log level from warnings to informational messages. Read when Facil is loaded. For diagnosing the C library. |
| `FACIL_JL_LOCAL_BUILD=1` | Prefer a locally built C library over a prebuilt one. Read when Facil is precompiled. |
| `libfacil_path` preference | Path of the C library to load, set with Preferences.jl. For developing the C code. |
