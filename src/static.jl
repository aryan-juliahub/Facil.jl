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

Sets the `content-type` sent for files ending in `.ext`, by `public_folder` and
[`sendfile`](@ref). Call it before serving; the table is process-wide.
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

The `content-type` for a file name, by extension; `application/octet-stream`
when the extension is unknown.
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
    sendfile(req, path; kw...)

A response that sends the file at `path` (taken as is, not URL-decoded) with
`sendfile(2)`. The `content-type` comes from the extension (see
[`Facil.mime_type`](@ref)), with `etag`, `last-modified`, `accept-ranges`,
answers to `If-None-Match` (304), `If-Range` and single-range `Range` requests
(206, 416), and HEAD and OPTIONS. When the client accepts gzip and `path.gz`
exists, that file is sent with `content-encoding: gzip`. A missing file gives
404; methods other than GET, HEAD and OPTIONS give 405. Headers given here are
sent too, except those the file sender sets itself.
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

static_folder(::Nothing) = nothing
function static_folder(dir::AbstractString)
    d = abspath(expanduser(String(dir)))
    occursin('\0', d) && throw(ArgumentError("public_folder must not contain NUL"))
    isdir(d) || throw(ArgumentError("public_folder $(repr(d)) is not a directory"))
    length(d) > 1 ? String(rstrip(d, '/')) : d
end
