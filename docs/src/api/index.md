# [API reference](@id api-reference)

This section documents every name Facil and HttpTypes export, and the public
names you call as `Facil.name`. Use it to look up an exact contract: the
signature, each argument with its type and default, what is returned, what is
thrown, and a small example that the documentation build runs.

The same text is in the REPL: type `?serve!`.

## How the reference is organised

| Page | What is on it |
|:--|:--|
| [Server](server.md) | [`serve`](@ref), [`serve!`](@ref), [`Server`](@ref) and stopping one |
| [Request bodies](requests.md) | `before_body` results ([`Buffer`](@ref), [`Stream`](@ref), [`Spool`](@ref), [`Reject`](@ref)), reading a body, and the client: [`client_address`](@ref), [`client_certificate`](@ref), [`isconnected`](@ref), [`on_disconnect`](@ref) |
| [Queries, forms and cookies](urls.md) | [`query_param`](@ref), [`query_params`](@ref), [`decoded_path`](@ref), [`parse_form`](@ref), [`cookies`](@ref), [`set_cookie!`](@ref) |
| [Responses](responses.md) | [`stream`](@ref), [`sse`](@ref), [`sendfile`](@ref), [`CompressOptions`](@ref) |
| [WebSockets and pub/sub](websockets.md) | [`websocket`](@ref), [`send`](@ref), [`publish`](@ref), [`subscribe`](@ref) |
| [HTTPS](tls.md) | [`TLSConfig`](@ref), [`reload!`](@ref), [`TLSError`](@ref) |
| [Timers](timers.md) | [`Facil.sleep`](@ref), [`every`](@ref), [`Facil.Timer`](@ref) |
| [Tuning and diagnostics](tuning.md) | [`Facil.gc_headroom!`](@ref) and the counters |
| [HttpTypes](httptypes/index.md) | [`Request`](@ref), [`Response`](@ref), [`HeaderMap`](@ref), [`Uri`](@ref), status codes, methods |

The request and response types come from HttpTypes. Facil re-exports all of
its names, so `using Facil` brings `Request`, `Response`, `StatusCodes`,
`Methods`, `header` and the rest into scope.

## Conventions

- **Exported and public names.** A name written bare, like `serve!`, is
  exported. A name written `Facil.sleep` is public but not exported, usually
  because Base has a function of the same name. Anything else inside the
  `Facil` module is internal and may change without notice.
- **Keyword defaults** are shown in the signature. `1 MiB` means `1024 * 1024`
  bytes.
- **Throws** lists what the call itself throws. Errors inside your callbacks
  are handled as described in [Errors and logging](../guide/errors.md).
- **Thread safety.** Unless an entry says otherwise, a function may be called
  from any task or thread. Callbacks state where they run: on the reactor
  thread (must not block) or on a task (may block).
- **Examples** start a server on port `0`, which picks a free port, and use
  the `Downloads` standard library as the client. In your own program you
  would pass a fixed port.

## All names

```@index
Modules = [Facil]
```
