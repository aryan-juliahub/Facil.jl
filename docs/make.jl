using Documenter
using Facil
using HttpTypes

makedocs(;
    sitename = "Facil.jl",
    modules = [Facil, HttpTypes],
    checkdocs = :exports,
    warnonly = false,
    remotes = nothing,
    format = Documenter.HTML(; prettyurls = get(ENV, "CI", nothing) == "true", edit_link = nothing, repolink = nothing),
    pages = [
        "Home" => "index.md",
        "Guide" => [
            "guide/routing.md",
            "guide/json.md",
            "guide/query.md",
            "guide/bodies.md",
            "guide/threads.md",
            "guide/gc.md",
            "guide/static.md",
            "guide/streaming.md",
            "guide/sse.md",
            "guide/compression.md",
            "guide/websockets.md",
            "guide/pubsub.md",
            "guide/tls.md",
            "guide/shutdown.md",
        ],
        "HttpTypes" => "httptypes.md",
        "Migrating from HTTP.jl" => "migrating_from_http_jl.md",
        "Benchmarks" => "benchmarks.md",
        "Known limits" => "limits.md",
        "API" => "api.md",
    ],
)
