# [JSON](@id json-guide)

This page shows how to receive and send JSON. Facil has no JSON code of its
own: the body of a request is a `String` and the body of a response is a
`String` or bytes, so any JSON package fits between them. The examples use
[JSON.jl](https://github.com/JuliaIO/JSON.jl) version 1; JSON3.jl and others
work the same way.

For a complete JSON API with routing, storage and tests, follow the
[tutorial](../getting-started/tutorial.md). This page is the reference for the
JSON part.

## A JSON endpoint

```@eval
Main.example("json_api.jl")
```

```sh
$ curl http://127.0.0.1:8080/greet -H 'Content-Type: application/json' -d '{"name":"Ada"}'
{"greeting":"hello Ada","length":3}
$ curl http://127.0.0.1:8080/greet -H 'Content-Type: application/json' -d '{not json'
{"error":"the body must be a JSON object"}
```

## Sending JSON

Serialise to a `String` and set the content type yourself:

```@example json
using Facil, JSON

res = Response(StatusCodes.OK, JSON.json((status = "ok", items = [1, 2, 3]));
               headers = [header.CONTENT_TYPE => "application/json"])
body(res)
```

- **Set `content-type`.** Without it Facil labels a `String` body
  `text/plain; charset=utf-8`, and browsers and HTTP clients will not treat it
  as JSON. JSON is UTF-8 by definition; `application/json` needs no `charset`.
- `content-length` is set by Facil.
- `JSON.json` accepts named tuples, dictionaries, vectors, numbers, strings,
  `nothing` (as `null`) and your own structs (as objects of their fields).
- A helper such as `json_response(status, data)` in the example keeps the
  header in one place. Build the header vector once (a `const`) if you like;
  each response still gets its own header map.

For large responses, turn on [compression](compression.md): JSON compresses
well.

## Reading JSON

[`body`](@ref)`(req)` is the request body as a `String`. Parse it:

```@example json
req = Request(Methods.POST, "/greet", """{"name":"Ada","tags":["a","b"]}""";
              headers = [header.CONTENT_TYPE => "application/json"])

data = JSON.parse(body(req))
data["name"], data["tags"]
```

`JSON.parse` returns objects as a dictionary type (`JSON.Object{String,Any}`),
arrays as `Vector{Any}`, and numbers, strings, booleans and `nothing`. It can
also parse straight into a struct:

```@example json
struct Greeting
    name::String
    tags::Vector{String}
end

JSON.parse(body(req), Greeting)
```

Three things go wrong with JSON from the network, and each deserves its own
answer:

| Problem | How you notice | Answer |
|---|---|---|
| The body is not JSON (or is empty) | `JSON.parse` throws | 400 |
| It is JSON but not the shape you expect | it is an array where you wanted an object, a field is missing or has the wrong type | 400 or 422 |
| The client sent something else (`text/plain`, a form) | the `content-type` header | 415 |

!!! warning "Catch parse errors"
    An exception that escapes the handler becomes a `500 Internal Server Error`
    and a stack trace in your log (see [Errors and logging](errors.md)). Bad
    input from a client is not a server error: wrap the parse in `try` and
    answer 400, as `json_body` does in the example.

Check types before you use values. `data["name"]` on an array throws, and a
`"name"` that is a number will break code that expects a string much later.
The example checks `data isa AbstractDict` and `name isa AbstractString`
before going on.

## Checking the content type

The `content-type` header may carry parameters (`application/json;
charset=utf-8`) and any letter case, so compare a lowercased prefix rather
than the whole value:

```@example json
function is_json(req)
    ct = get(headers(req), header.CONTENT_TYPE, nothing)
    ct !== nothing && startswith(lowercase(as_str(ct)), "application/json")
end

is_json(req), is_json(Request(Methods.POST, "/greet", "name=Ada"))
```

## Large bodies

By default a request body is read into memory before the handler runs, up to
`body_in_memory` (16 MiB); a larger body is answered with 413 by Facil and
your handler is not called. A JSON API rarely needs megabytes: lower the limit
to what you expect, as the example does with `body_in_memory = 1024 * 1024`.
That 413 has a plain-text body, not your API's JSON error format.

`JSON.parse` needs the whole document, so there is nothing to gain from
streaming a JSON body. For genuinely large uploads, take newline-delimited
JSON and parse it line by line from [`body_stream`](@ref)`(req)`; see
[Request bodies and uploads](bodies.md).

For large JSON responses, building the string is usually the dominant cost,
not sending it (the benchmarks record this for a 50 KB response; see
[Benchmarks](../reference/benchmarks.md)). If the document does not change
between requests, serialise it once and return the same `String` every time:
bodies are sent without a copy.

## See also

- The [tutorial](../getting-started/tutorial.md) builds a JSON API step by step.
- [Reading requests](requests.md) for query parameters and headers.
- [Sending responses](responses.md) for status codes and headers.
- [Routing](routing.md).
- API: [`body`](@ref), [`Response`](@ref), [`header`](@ref).
