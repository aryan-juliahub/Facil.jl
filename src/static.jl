# Static files: facil.io's file sender (sendfile(2), ETag, Last-Modified,
# conditional requests, single ranges, HEAD), used by `public_folder` and by
# `sendfile` responses, with a MIME table for current web formats.

const UTF8 = "; charset=utf-8"

# Overrides and additions to facil.io's built-in table (keyed by extension).
const MIME_TYPES = Dict(
    "html" => "text/html" * UTF8, "htm" => "text/html" * UTF8, "css" => "text/css" * UTF8,
    "js" => "text/javascript" * UTF8, "mjs" => "text/javascript" * UTF8, "cjs" => "text/javascript" * UTF8,
    "json" => "application/json", "map" => "application/json", "jsonld" => "application/ld+json",
    "webmanifest" => "application/manifest+json", "txt" => "text/plain" * UTF8, "md" => "text/markdown" * UTF8,
    "csv" => "text/csv" * UTF8, "xml" => "application/xml", "svg" => "image/svg+xml",
    "wasm" => "application/wasm", "ico" => "image/vnd.microsoft.icon", "png" => "image/png",
    "jpg" => "image/jpeg", "jpeg" => "image/jpeg", "gif" => "image/gif", "webp" => "image/webp",
    "avif" => "image/avif", "woff" => "font/woff", "woff2" => "font/woff2", "ttf" => "font/ttf",
    "otf" => "font/otf", "pdf" => "application/pdf", "zip" => "application/zip", "gz" => "application/gzip",
    "mp4" => "video/mp4", "webm" => "video/webm", "mp3" => "audio/mpeg", "ogg" => "audio/ogg",
    "wav" => "audio/wav", "yaml" => "application/yaml", "yml" => "application/yaml",
    "toml" => "application/toml", "jl" => "text/plain" * UTF8,
)

function init_static()
    for (ext, t) in MIME_TYPES
        register_mime!(ext, t)
    end
    nothing
end

"""
    Facil.register_mime!(ext, type)

Set the `content-type` sent for files whose name ends in `.ext`, by
`public_folder` and [`sendfile`](@ref).

# Arguments
- `ext::AbstractString`: the extension, with or without the leading dot; case
  is ignored. 1 to 15 bytes.
- `type::AbstractString`: the full header value, for example
  `"text/x-log; charset=utf-8"`.

# Throws
- `ArgumentError` for an empty or over-long extension, or a type containing a
  NUL or a line break.

# Notes
The table is process-wide and shared by every server. Register before the
first request for such a file. Registering an extension again replaces it.

# Examples
```jldoctest
julia> using Facil

julia> Facil.register_mime!(".log", "text/x-log; charset=utf-8")

julia> Facil.mime_type("server.log")
"text/x-log; charset=utf-8"
```
"""
function register_mime!(ext::AbstractString, type::AbstractString)
    e = lowercase(String(lstrip(ext, '.')))
    t = String(type)
    (isempty(e) || sizeof(e) > 15) && throw(ArgumentError("extension must be 1–15 bytes"))
    (occursin('\0', t) || occursin('\n', t)) && throw(ArgumentError("invalid MIME type"))
    GC.@preserve e t @ccall LIBFJL.fjl_mime_register(pointer(e)::Ptr{UInt8}, sizeof(e)::Csize_t, pointer(t)::Ptr{UInt8}, sizeof(t)::Csize_t)::Cvoid
    nothing
end

"""
    Facil.mime_type(path) -> String

The `content-type` Facil sends for a file name, chosen by its extension
(case-insensitive). Returns `"application/octet-stream"` for an unknown
extension or none. The file does not have to exist.

# Examples
```jldoctest
julia> using Facil

julia> Facil.mime_type("index.html")
"text/html; charset=utf-8"

julia> Facil.mime_type("photo.JPG")
"image/jpeg"

julia> Facil.mime_type("data.unknown")
"application/octet-stream"
```
"""
function mime_type(path::AbstractString)
    _, ext = splitext(basename(path))
    e = lowercase(String(lstrip(ext, '.')))
    (isempty(e) || sizeof(e) > 15) && return OCTET_STREAM
    buf = Vector{UInt8}(undef, 256)
    n = GC.@preserve e buf @ccall LIBFJL.fjl_mime_find(pointer(e)::Ptr{UInt8}, sizeof(e)::Csize_t, pointer(buf)::Ptr{UInt8}, 256::Csize_t)::Csize_t
    n == 0 ? OCTET_STREAM : String(resize!(buf, n))
end

"Body of a file response; see [`sendfile`](@ref)."
struct FileBody
    path::String
end

"""
    sendfile(path; status = 200, headers = []) -> Response
    sendfile(req, path; status = 200, headers = []) -> Response

Answer with the contents of the file at `path`, sent by the kernel
(`sendfile(2)`) without passing through Julia.

Return the result from your handler.

# Arguments
- `path::AbstractString`: the file to send. It is used as given: not
  URL-decoded, not checked against any root directory. Never build it from the
  request target without validating it yourself.
- `req`: accepted and ignored, so `sendfile(req, path)` reads like the other
  response functions.

# Keywords
- `status = 200`: the status for a full response.
- `headers = []`: extra headers, as `name => value` pairs or a
  [`HeaderMap`](@ref). Headers the file sender sets itself win.

# Returns
A [`Response`](@ref) to return from the handler. The file is opened when the
response is sent, not when `sendfile` is called.

# Throws
- `ArgumentError` if `path` contains a NUL.

# What the client gets
- `content-type` from the extension (see [`Facil.mime_type`](@ref)),
  `content-length`, `etag`, `last-modified` and `accept-ranges: bytes`.
- `304 Not Modified` for a matching `If-None-Match`.
- `206 Partial Content` for a single-range `Range` request (honouring
  `If-Range`), `416` for a range outside the file.
- The head only, for `HEAD`. An `allow` header for `OPTIONS`.
- `path * ".gz"` instead, with `content-encoding: gzip`, when that file exists
  and the client accepts gzip.
- `404` if the file does not exist; `405` with `allow: GET, HEAD, OPTIONS` for
  any other method.

# Examples
```jldoctest
julia> using Facil

julia> import Downloads

julia> dir = mktempdir(); write(joinpath(dir, "report.csv"), "a,b\\n1,2\\n");

julia> server = serve!(0) do req
           sendfile(joinpath(dir, "report.csv"); headers = ["content-disposition" => "attachment"])
       end;

julia> out = IOBuffer();

julia> r = Downloads.request("http://127.0.0.1:\$(port(server))/"; output = out);

julia> String(take!(out))
"a,b\\n1,2\\n"

julia> Dict(r.headers)["content-type"]
"text/csv; charset=utf-8"

julia> close(server)
```

See the [static files guide](@ref static-guide).
"""
function sendfile(path::AbstractString; status = StatusCodes.OK, headers = HeaderMap{HeaderValue}())
    p = String(path)
    occursin('\0', p) && throw(ArgumentError("path must not contain NUL"))
    Response(StatusCode(status), FileBody(p); headers)
end
sendfile(req::Request, path::AbstractString; kw...) = sendfile(path; kw...)

compress_response(req, res::Response{FileBody}, ::CompressOptions) = res

@noinline function respond(h::Ptr{Cvoid}, res::Response{FileBody})
    p = res.body.path
    write_headers(h, res.headers)
    if isfile(p)
        st = Cint(UInt16(res.status))
        r = GC.@preserve p @ccall LIBFJL.fjl_sendfile(h::Ptr{Cvoid}, st::Cint, pointer(p)::Ptr{UInt8}, sizeof(p)::Csize_t)::Cint
        r == 0 && return nothing
        set_header(h, HttpTypes.standard_index(header.ALLOW), "allow", "GET, HEAD, OPTIONS")
        fail(h, 405)
    else
        fail(h, 404)
    end
    nothing
end

const PUBLIC_DENY_DOTFILES = 0x01
const PUBLIC_CONTAIN_SYMLINKS = 0x02

static_folder(::Nothing, ::Symbol) = nothing
function static_folder(dir::AbstractString, symlinks::Symbol)
    d = abspath(expanduser(String(dir)))
    occursin('\0', d) && throw(ArgumentError("public_folder must not contain NUL"))
    isdir(d) || throw(ArgumentError("public_folder $(repr(d)) is not a directory"))
    # Containment compares resolved paths, so the folder is resolved too.
    symlinks === :inside && (d = realpath(d))
    length(d) > 1 ? String(rstrip(d, '/')) : d
end

function static_flags(dir, dotfiles::Symbol, symlinks::Symbol)
    dotfiles in (:serve, :deny) || throw(ArgumentError("dotfiles must be :serve or :deny, got $(repr(dotfiles))"))
    symlinks in (:follow, :inside) || throw(ArgumentError("symlinks must be :follow or :inside, got $(repr(symlinks))"))
    dir === nothing && (dotfiles, symlinks) != (:serve, :follow) &&
        throw(ArgumentError("dotfiles and symlinks apply to public_folder, which is not set"))
    (dotfiles === :deny ? PUBLIC_DENY_DOTFILES : 0x00) | (symlinks === :inside ? PUBLIC_CONTAIN_SYMLINKS : 0x00)
end
