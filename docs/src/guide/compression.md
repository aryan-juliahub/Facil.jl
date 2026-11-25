# Compression

`compress = true` compresses handler results with zstd, brotli or gzip, picked
from the request's `Accept-Encoding` (q-values honoured). It sets
`content-encoding` and `vary: accept-encoding`.

```julia
using Facil

const PAGE = repeat("<p>hello</p>\n", 500)

serve("127.0.0.1", 8080; compress = true) do req
    Response(StatusCodes.OK, PAGE; headers = [header.CONTENT_TYPE => "text/html"])
end
```

These are sent as they are: bodies under 1 KiB, responses that already have a
`content-encoding`, responses with `cache-control: no-transform`, and content
types that `Facil.compressible_type` rejects (it accepts `text/*`, JSON,
JavaScript, XML, SVG, WebAssembly and a few other text formats).

Compression runs where the handler runs: on its task for task handlers, on the
reactor for inline handlers. gzip uses libdeflate (zlib-ng for long streams),
zstd uses libzstd and brotli uses libbrotli; Julia's bundled zlib is not used.

`CompressOptions` sets the preference order, levels, minimum size and type test:

```julia
using Facil

opts = CompressOptions(prefer = (:gzip, :br), gzip = 9, min_size = 256)

serve("127.0.0.1", 8080; compress = opts) do req
    Response(StatusCodes.OK, repeat("{\"n\":1}", 100); headers = [header.CONTENT_TYPE => "application/json"])
end
```

`Facil.gzip`, `Facil.zstd` and `Facil.brotli` compress a byte vector or string
directly. Static files are not compressed on the fly; put a `.gz` file next to
the original instead (see [Static files](static.md)).
