# [Static files](@id static-guide)

This page shows the two ways to send files: `public_folder`, which serves a
directory without calling your handler, and [`sendfile`](@ref), which sends
one file from a handler. Both use facil.io's file sender, so both get caching
headers, conditional requests, ranges and `sendfile(2)`.

## A site with public and private files

```@eval
Main.example("static_site.jl")
```

With this layout next to the script:

```
public/index.html
public/app.css
public/app.css.gz
public/docs/index.html
reports/q3.csv
```

```sh
$ curl http://127.0.0.1:8080/docs/
docs index
$ curl http://127.0.0.1:8080/reports/q3.csv
quarter,revenue
q3,100
$ curl http://127.0.0.1:8080/missing.html
no such page
```

## Serving a directory with `public_folder`

`public_folder = dir` is a keyword of [`serve!`](@ref). Before the handler is
called, Facil looks for the request's path under `dir`:

- A **GET, HEAD or OPTIONS** request for a file that exists is answered from
  the folder. The handler is not called, and `before_body`, `compress` and
  your own headers do not apply.
- A path ending in `/` serves `index.html` from that directory (`/` serves
  `dir/index.html`).
- **Everything else reaches the handler**: other methods, paths with no file,
  directories without `index.html`, and a directory named without its trailing
  slash (`/docs` is not redirected to `/docs/`).

The path is percent-decoded before the lookup (`/release%20notes.txt` finds
`release notes.txt`) and the query string is ignored. Files are looked up at
request time: files you add or change while the server runs are served
without a restart.

`dir` is resolved to an absolute path when the server starts, relative to the
directory Julia was started in; a directory that does not exist throws an
`ArgumentError` there.

!!! warning "Everything in the folder is public"
    - Paths containing `..` are never served from the folder; they reach your
      handler, with the `..` still in `path(uri(req))`.
    - **Dotfiles are served**: `public/.env` answers `/.env`.
    - **Symbolic links are followed**, also out of the folder. A link inside
      `public` to a file or directory elsewhere publishes that target.

    Put only files meant for the world in the folder, and do not point it at a
    project root or a directory that holds uploads you have not vetted.

## Sending one file with `sendfile`

[`sendfile`](@ref)`(path)` returns a response that sends the file at `path`.
Use it for files outside the public folder, downloads behind a login, and
files whose name you compute.

| Case | Answer |
|---|---|
| the file exists, method GET or HEAD | the file (or its head), with `status` (default 200) |
| method OPTIONS | 200 with `allow: GET, HEAD` |
| any other method | 405 with `allow: GET, HEAD, OPTIONS` |
| `path` is missing or is a directory | 404 |

Headers you pass with `headers` are sent too, except the ones the file sender
sets itself (`content-type`, `etag`, `cache-control`, `last-modified`,
`content-length`, `accept-ranges`, `content-range`, `content-encoding`).

!!! warning "`sendfile` trusts its path"
    The path is used as given: it is not percent-decoded and not confined to
    any folder. `sendfile(joinpath(dir, user_input))` lets a request for
    `../../etc/passwd` out of `dir`. Check request text against a strict
    pattern first, as the example does, or look the name up in a list of files
    you know.

`sendfile(req, path)` is the same; the request is accepted for symmetry with
[`stream`](@ref) and not used.

## What the file sender does

For `public_folder` and `sendfile` alike:

| Feature | Behaviour |
|---|---|
| `content-type` | from the file extension; `application/octet-stream` when unknown |
| `etag` | derived from the file's size and modification time |
| `last-modified` | the file's modification time |
| `cache-control` | always `max-age=3600` |
| `If-None-Match` | 304 when the ETag matches |
| `If-Modified-Since` | ignored: the file is sent |
| `Range` | one range (`bytes=0-99`, `bytes=100-`, `bytes=-50`) gives 206 with `content-range`; an unsatisfiable one gives 416; several ranges give the whole file with 200 |
| `If-Range` | honoured with an ETag |
| HEAD | headers only |
| gzip | when the client's `Accept-Encoding` has gzip and `file.gz` exists next to `file`, the `.gz` file is sent with `content-encoding: gzip` |

Things to know:

- **Caching cannot be changed.** Every file is sent with
  `cache-control: max-age=3600`, and a `cache-control` you pass to `sendfile`
  is replaced. Browsers may reuse a file for an hour without asking. Put a
  version or content hash in file names you change in place (`app.3f9a.css`),
  or serve such files from a handler as an ordinary `Response`.
- **The ETag is not a content hash.** A file rewritten within the same second
  with the same size keeps its ETag.
- **Files are not compressed on the fly**, whatever `compress` says. Create
  the `.gz` sibling when you build your assets (`gzip -k -9 app.css`). Only
  gzip siblings are looked for, not `.br` or `.zst`.

## Content types

The type comes from the extension, case-insensitively, from facil.io's table
plus Facil's additions for current web formats (`.js` and `.mjs` as
`text/javascript`, `.wasm`, `.webp`, `.avif`, `.woff2`, `.webmanifest`,
`.svg`, `.json`, `.md`, and so on; text types carry `charset=utf-8`).

[`Facil.mime_type`](@ref)`(path)` tells you what a name maps to, and
[`Facil.register_mime!`](@ref)`(ext, type)` adds or replaces an entry:

```@example static
using Facil

Facil.mime_type("index.html"), Facil.mime_type("photo.JPG"), Facil.mime_type("data.parquet")
```

```@example static
Facil.register_mime!("parquet", "application/vnd.apache.parquet")
Facil.mime_type("data.parquet")
```

The table is process-wide and has no lock: register your types before the
first server starts. An extension is 1 to 15 bytes, without the dot (a leading
dot is dropped).

## See also

- [Compression](compression.md) for compressing handler responses.
- [Sending responses](responses.md) for serving small generated files as
  ordinary responses.
- [Security notes](security.md) for more on what a server exposes.
- API: [`sendfile`](@ref), [`serve!`](@ref) (`public_folder`),
  [`Facil.register_mime!`](@ref), [`Facil.mime_type`](@ref).
