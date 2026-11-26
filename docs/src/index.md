# Facil.jl

Facil is an HTTP/1.1 server for Julia built on [facil.io](https://github.com/boazsegev/facil.io),
a C library. facil.io does the sockets, the event loop, HTTP parsing, static files,
WebSockets, server-sent events, pub/sub, timers and TLS. Julia handlers receive and
return the types of [HttpTypes](httptypes.md), a pure-Julia port of the Rust
[`http`](https://github.com/hyperium/http) crate (version 1.5.0). Facil re-exports
HttpTypes, so `using Facil` is enough.

```julia
using Facil

serve("127.0.0.1", 8080) do req
    Response(StatusCodes.OK, "hello")
end
```

```
$ curl http://127.0.0.1:8080/
hello
```

`serve` blocks; `serve!` returns a `Server` at once. A handler gets a
`Request{String}` and returns a `Response` (body `String`, `Vector{UInt8}` or
`nothing`) or a `String`.

## Installation

Facil is not registered yet, and the prebuilt library (`facil_julia_jll`) is not
published. Until it is, installing needs a C compiler (`clang` or `gcc`) and a
local build:

```sh
git clone --recurse-submodules <repository URL> Facil.jl
cd Facil.jl
julia --project -e 'using Pkg; Pkg.instantiate()'
julia --project deps/build.jl
```

Julia 1.10 or later on Linux or macOS; CI tests Linux x86_64 and macOS (arm64 and
x86_64). Windows is not supported (facil.io has no Windows port): on Windows, run
Facil inside WSL2. HttpTypes (`lib/HttpTypes`) is pure Julia and works natively on
Windows.

## Where to go next

- The [guide](guide/routing.md) has one short page per feature, each with an example
  that was run against the package.
- [HttpTypes](httptypes.md) maps the Rust crate's names to Julia's.
- [Migrating from HTTP.jl](migrating_from_http_jl.md) shows handlers side by side.
- [Benchmarks](benchmarks.md) has the full Node.js scoreboard, failures included.
- [Known limits](limits.md) lists what Facil does not do.
