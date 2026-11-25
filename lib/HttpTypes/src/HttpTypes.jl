"""
    HttpTypes

Common HTTP types: methods, status codes, versions, header names and values, a
header multimap, URIs, extensions, requests and responses. A port of the Rust
`http` crate.
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
