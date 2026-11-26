"""
    HttpTypes

Common HTTP types: methods, status codes, protocol versions, header names and
values, a header multimap, URIs, extensions, requests and responses. A pure-Julia
port of the Rust `http` crate, version 1.5.0, with the crate's validation rules.

The package only describes HTTP messages; it does no I/O. Values are validated
when they are built, so a `Request` or `Response` you hold is always well formed.

- [`HttpMethod`](@ref) and `Methods`, [`StatusCode`](@ref) and `StatusCodes`,
  [`Version`](@ref) and `Versions`
- [`HeaderName`](@ref) and `header`, [`HeaderValue`](@ref), [`HeaderMap`](@ref)
- [`Uri`](@ref) with [`Scheme`](@ref), [`Authority`](@ref), [`PathAndQuery`](@ref),
  [`Port`](@ref)
- [`Request`](@ref), [`Response`](@ref), [`Extensions`](@ref)
- every error is an [`HttpError`](@ref)

Constructors throw on invalid input; `tryparse(T, src)` returns `nothing` instead.
`show` prints Julia that reads back (`Methods.GET`, `hn"accept"`, `uri"/a"`);
`print` and `string` give the text that goes on the wire.

# Examples
```jldoctest
julia> req = Request(; method = "POST", uri = "/users?page=2", headers = ["Accept" => "*/*"], body = "{}");

julia> method(req), path(uri(req)), query(uri(req))
(Methods.POST, "/users", "page=2")

julia> headers(req)["accept"]
hv"*/*"

julia> string(status(Response(StatusCodes.NOT_FOUND)))
"404 Not Found"
```
"""
module HttpTypes

include("bytes.jl")
include("error.jl")
include("method.jl")
include("status.jl")
include("version.jl")
include("header/name.jl")
include("header/value.jl")
include("header/map.jl")
include("uri/scheme.jl")
include("uri/authority.jl")
include("uri/path.jl")
include("uri/port.jl")
include("uri/uri.jl")
include("extensions.jl")
include("request.jl")
include("response.jl")

end
