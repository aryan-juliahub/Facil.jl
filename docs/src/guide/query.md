# Query parameters

`query(uri(req))` is the raw query string, or `nothing` when the URL has none.
Facil and HttpTypes do not split or percent-decode it. `URIs.queryparams` from
[URIs.jl](https://github.com/JuliaWeb/URIs.jl) does both:

```julia
using Facil, URIs

serve("127.0.0.1", 8080) do req
    q = queryparams(something(query(uri(req)), ""))
    name = get(q, "name", "world")
    n = something(tryparse(Int, get(q, "n", "1")), 1)
    Response(StatusCodes.OK, join(fill("hello $name", n), "\n"))
end
```

```
$ curl 'http://127.0.0.1:8080/?name=Ada%20L&n=2'
hello Ada L
hello Ada L
```
