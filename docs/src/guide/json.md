# JSON

Facil has no JSON dependency. Use any JSON package; the examples use
[JSON.jl](https://github.com/JuliaIO/JSON.jl).

```julia
using Facil, JSON

const JSON_TYPE = [header.CONTENT_TYPE => "application/json"]

serve("127.0.0.1", 8080) do req
    if method(req) == Methods.POST
        data = JSON.parse(body(req))
        Response(StatusCodes.CREATED, JSON.json(Dict("hello" => data["name"])); headers = JSON_TYPE)
    else
        Response(StatusCodes.OK, JSON.json((status = "ok", path = path(uri(req)))); headers = JSON_TYPE)
    end
end
```

- `body(req)` is the request body as a `String`.
- Set `content-type` yourself. Without it a `String` body is sent as
  `text/plain; charset=utf-8` and a `Vector{UInt8}` body as `application/octet-stream`.
- `content-length` is always set by Facil.
