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
- A directory named without its trailing slash (`/docs`) that has an
  `index.html` gets a `301` redirect to the path with the slash (`/docs/`),
  query string kept, as nginx and `serve-static` do. That is what makes
  relative links inside `docs/index.html` resolve.
- **Everything else reaches the handler**: other methods, paths with no file,
  and directories without `index.html`.

The path is percent-decoded before the lookup (`/release%20notes.txt` finds
`release notes.txt`) and the query string is ignored. Files are looked up at
request time: files you add or change while the server runs are served
without a restart.

`dir` is resolved to an absolute path when the server starts, relative to the
directory Julia was started in; a directory that does not exist throws an
`ArgumentError` there.

!!! warning "Everything in the folder is public"
    Dotfiles are not served by default, but symbolic links are followed, also
    out of the folder. Put only files meant for the world in the folder, and
    do not point it at a project root or a directory that holds uploads you
    have not vetted.

## What is never served, and what you can turn off

| Request path | Result |
|---|---|
| contains `..` as a path part, or `//` (also when percent-encoded) | never served from the folder; reaches your handler, with the path as sent |
| contains an encoded NUL (`%00`) | `400 Bad Request`; the handler is not called |
| has a part that starts with a dot (`/.env`, `/.git/config`) | not served by default (`dotfiles = :deny`): it reaches your handler as if the file did not exist. `/.well-known/...` (RFC 8615: ACME challenges, `security.txt`) is served. `dotfiles = :serve` serves every dotfile |
| names a symbolic link, or goes through one | followed by default; with `symlinks = :inside` a file that resolves to a place outside the folder reaches your handler instead |

```julia
serve!(app, 8080; public_folder = "public", symlinks = :inside)
```

The defaults are those of Node's `serve-static`, which ignores dotfiles and
follows links; `dotfiles = :serve` serves dotfiles as nginx does. Turn on `symlinks = :inside` when other people or tools can put files into
the folder. With `symlinks = :inside`, links that stay
inside the folder still work, and the folder itself may be reached through a
link.

## Caching

Files from the folder are sent with `cache-control: max-age=3600`: browsers
may reuse a file for an hour without asking. Choose another policy with the
`static_cache_control` keyword:

```julia
# fingerprinted assets (app.3f9a.css) never change under their name
serve!(app, 8080; public_folder = "dist", static_cache_control = "public, max-age=31536000, immutable")

# always revalidate: a cheap 304 while the file is unchanged
serve!(app, 8080; public_folder = "public", static_cache_control = "no-cache")

# no cache-control header at all
serve!(app, 8080; public_folder = "public", static_cache_control = nothing)
```

Revalidation works with both validators the file sender emits: a request
with `If-None-Match` (the ETag) or `If-Modified-Since` (the
`last-modified` date) gets an empty `304 Not Modified` while the file is
unchanged.

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
| `cache-control` | `max-age=3600`; for `public_folder` files, the `static_cache_control` keyword |
| `If-None-Match` | 304 when the ETag matches |
| `If-Modified-Since` | 304 when the file is not newer than the date; ignored when `If-None-Match` is present (RFC 9110) |
| `Range` | one range (`bytes=0-99`, `bytes=100-`, `bytes=-50`) gives 206 with `content-range`; an unsatisfiable one gives 416; several ranges give the whole file with 200 |
| `If-Range` | honoured with an ETag |
| HEAD | headers only |
| gzip | when the client's `Accept-Encoding` has gzip and `file.gz` exists next to `file`, the `.gz` file is sent with `content-encoding: gzip` |

Things to know:

- **Caching** is set per server for the public folder (see [Caching](#Caching)
  below). A file from `sendfile` is always sent with
  `cache-control: max-age=3600`, and a `cache-control` you pass to `sendfile`
  is replaced.
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
