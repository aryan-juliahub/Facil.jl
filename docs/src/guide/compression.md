# [Compression](@id compression-guide)

This page shows how to compress response bodies: turning it on for a server
with `compress`, tuning it with [`CompressOptions`](@ref), compressing streamed
responses, and compressing data yourself with `Facil.gzip`, `Facil.zstd` and
`Facil.brotli`.

## Turning it on

`compress = true` is a keyword of [`serve!`](@ref). Facil then compresses what
your handler returns, when the client accepts an encoding and the response is
worth compressing:

```@eval
Main.example("compression_basic.jl")
```

```sh
$ curl -s -H 'Accept-Encoding: gzip' -D - -o /dev/null http://127.0.0.1:8080/ | grep -i -e content-encoding -e vary
content-encoding:gzip
vary:accept-encoding
$ curl -s --compressed http://127.0.0.1:8080/ | head -2
<p>hello</p>
<p>hello</p>
```

Compression is off by default. A reverse proxy in front of Facil often
compresses already; do it in one place.

## How the encoding is chosen

Facil supports **zstd**, **brotli** (`br`) and **gzip**. For each response:

1. It reads the request's `Accept-Encoding`. Encodings with `q=0` are out; `*`
   stands for any encoding not named.
2. Among the encodings the client accepts, the one with the highest q-value
   wins. Ties, which is the usual case since browsers send no q-values, go to
   the encoding listed first in `prefer` (default `zstd`, then `br`, then
   `gzip`).
3. The body is compressed, `content-encoding` is set, and `content-length` is
   that of the compressed body.

A request without `Accept-Encoding` gets the body as it is.

Facil adds `vary: accept-encoding` to every response that it would compress for
some client, compressed or not, so that caches keep the variants apart. An
existing `vary` header that already covers it is left alone.

## What is not compressed

A response is sent as it is when any of these holds:

| Condition | Why |
|---|---|
| the body is smaller than `min_size` (1024 bytes) | the saving does not pay for the work |
| it already has a `content-encoding` | it is compressed already |
| it has `cache-control: no-transform` | you asked for the exact bytes |
| its `content-type` is not compressible | images, video, archives and fonts in WOFF are compressed formats |
| the status is below 200, or 204, 206 or 304 | no body, or a body that must not change |
| the compressed body is not smaller | nothing gained |
| it is a file (`sendfile`, `public_folder`) or an event stream | see [Static files](static.md) for `.gz` siblings |

Whether a type is compressible is decided by
[`Facil.compressible_type`](@ref): `text/*`, JSON, JavaScript, XML, anything
ending in `+json` or `+xml`, SVG, WebAssembly, TTF and OTF fonts, and a few
other text formats. A response without a `content-type` counts as
`text/plain` for a string body and `application/octet-stream` (not
compressible) for a byte body.

```@example compression
using Facil

Facil.compressible_type.(["text/html; charset=utf-8", "application/json", "image/svg+xml", "image/png", "font/woff2"])
```

## Options

Pass a [`CompressOptions`](@ref) instead of `true` to change the defaults:

| Keyword | Default | Meaning |
|---|---|---|
| `prefer` | `(:zstd, :br, :gzip)` | encodings offered, in order of preference; leave one out to disable it |
| `gzip` | `6` | gzip level, 1 to 12 |
| `br` | `4` | brotli quality, 0 to 11 |
| `zstd` | `3` | zstd level, -7 to 22 |
| `min_size` | `1024` | smallest body, in bytes, that is compressed |
| `compressible` | `Facil.compressible_type` | function from a content type to `true` or `false` |

```@eval
Main.example("compression_options.jl")
```

The defaults favour speed: they are the levels at which compressing on every
request is reasonable. For content that never changes, compress once at a high
level and send the result with its `content-encoding` set, as `/archive` does.
Then check the request's `Accept-Encoding` yourself, or serve only clients you
know.

## Streamed responses

A [`stream`](@ref) is compressed as it is written:

- With the default `compress = :auto`, a stream follows the server's `compress`
  option and the request's `Accept-Encoding`, like any other response (the
  `min_size` test does not apply: the length is unknown).
- `compress = :gzip`, `:br` or `:zstd` on the `stream` call compresses with
  that encoding whatever the client or the server option says. Use it only when
  you know the client.
- `compress = nothing` never compresses that stream.

Compressors buffer. A piece you write may not reach the client until enough
data has accumulated; `flush(io)` ends a compressed block and sends it, at
some cost in ratio. Flush where a client must see progress, not after every
write.

## Where the work happens

Compression runs on the thread that runs your code: the worker task for task
handlers and for streams written from a task, the reactor thread for inline
handlers. Compressing a large body in an inline handler stalls the other
connections of that reactor for as long as it takes; use task handlers (the
default) for servers that compress large responses. See
[Handlers and concurrency](handlers.md).

The codecs are libdeflate (gzip of whole bodies and of short streams), zlib-ng
(gzip of long streams), libzstd and libbrotli, all shipped as Julia artifacts.
Julia's own zlib is not used for HTTP compression. (The C library links the
system zlib only for facil.io's fallback WebSocket permessage-deflate codec.)

## Compressing data yourself

Three functions compress a `String` or byte vector in one call and return a
`Vector{UInt8}`:

```@example compression
data = repeat("the same line again and again\n", 1000)

sizeof(data), length(Facil.gzip(data)), length(Facil.zstd(data)), length(Facil.brotli(data))
```

```@example compression
length(Facil.gzip(data; level = 12)), length(Facil.zstd(data; level = 19)), length(Facil.brotli(data; level = 11))
```

They are not exported; call them as `Facil.gzip` and so on. There are no
public decompression functions: Facil is a server and only compresses.

## See also

- [Static files](static.md) for precompressed `.gz` files.
- [Streaming responses](streaming.md).
- [Performance tuning](performance.md) and the
  [benchmarks](../reference/benchmarks.md) for measured compression throughput.
- API: [`CompressOptions`](@ref), [`Facil.compressible_type`](@ref),
  [`Facil.compress_response`](@ref), [`Facil.gzip`](@ref),
  [`Facil.zstd`](@ref), [`Facil.brotli`](@ref).
