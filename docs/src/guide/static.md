# Static files

`public_folder` serves a directory before the handler is called. GET, HEAD and
OPTIONS requests for files that exist are answered from the folder; everything
else reaches the handler. `/` serves `index.html`. `sendfile(path)` returns a
file from a handler.

```julia
using Facil

serve("127.0.0.1", 8080; public_folder = "public") do req
    if path(uri(req)) == "/report"
        sendfile("data/report.csv"; headers = [header.CONTENT_DISPOSITION => "attachment"])
    else
        Response(StatusCodes.NOT_FOUND, "no such page")
    end
end
```

Both send the file with `sendfile(2)` and set `content-type` from the extension,
`etag`, `last-modified` and `accept-ranges`. They answer `If-None-Match` (304),
`If-Range`, single-range `Range` requests (206, 416), HEAD and OPTIONS. When the
client accepts gzip and `file.gz` exists next to `file`, the `.gz` file is sent
with `content-encoding: gzip`.

`Facil.register_mime!(ext, type)` adds or changes a content type;
`Facil.mime_type(path)` looks one up. `sendfile` takes the path as given; it does
not URL-decode it or check that it stays inside a folder, so do not pass request
paths to it unchecked.
