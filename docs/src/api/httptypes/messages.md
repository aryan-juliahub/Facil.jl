```@meta
CurrentModule = HttpTypes
```

# Requests and responses

This page documents [`Request`](@ref) and [`Response`](@ref), the two message
types, their accessors, and the body-less heads [`RequestParts`](@ref) and
[`ResponseParts`](@ref). A Facil handler receives a `Request{String}` and
returns a `Response`; use this page to see every way to read the one and build
the other.

## Reading a request

A request has six parts, each with an accessor of the same name as its field:

```@repl msg
using HttpTypes
req = Request(; method = "POST", uri = "/users?page=2",
              headers = ["Content-Type" => "application/json"], body = "{\"name\":\"ada\"}");
method(req)
uri(req)
version(req)
headers(req)
body(req)
extensions(req)
```

The type parameter is the type of the body: this one is a `Request{String}`.
The pages on [methods](methods.md), [URIs](uri.md), [headers](headers.md) and
[extensions](extensions.md) cover what you can do with each part.

## Building a response

The usual form is a status and a body, with headers as a keyword:

```@repl msg
Response(StatusCodes.OK, "hello")
Response(StatusCodes.CREATED, "{}"; headers = [header.CONTENT_TYPE => "application/json",
                                                header.LOCATION => "/users/7"])
```

A response without a body takes the status alone, and a body alone gets
status 200:

```@repl msg
Response(StatusCodes.NO_CONTENT)
Response("hello")
```

The status may be an integer when a body follows it. A single integer argument
is refused, because it could be either a status or a body:

```@repl msg
status(Response(404, "not found"))
try
    Response(404)
catch e
    sprint(showerror, e)
end
```

| Call | Status | Body |
|:--|:--|:--|
| `Response(StatusCodes.NOT_FOUND)` | 404 | `nothing` |
| `Response(StatusCode(404))` | 404 | `nothing` |
| `Response(404, "not found")` | 404 | `"not found"` |
| `Response(StatusCodes.NOT_FOUND, "not found")` | 404 | `"not found"` |
| `Response(; status = 404)` | 404 | `nothing` |
| `Response("not found")` | 200 | `"not found"` |
| `Response(404)` | throws `ArgumentError` | |

## Changing a message

Messages are mutable. Assign a field to replace it (the value is converted and
validated), and change headers and extensions in place:

```@repl msg
res = Response(StatusCodes.OK, "hello");
res.status = 404;
res.body = "gone";
headers(res)[header.CACHE_CONTROL] = "no-store";
res
```

`map` builds a message with a transformed body, and `parts` splits the head
from the body so that it can be reused with another one:

```@repl msg
body(map(uppercase, res))
head = parts(res)
Response(head, codeunits("bytes")) isa Response{<:AbstractVector{UInt8}}
```

`map` and `parts` share the headers and extensions of the original instead of
copying them.

## Reference

```@docs
Request
Response
method
uri
status
version
headers
extensions
body
parts
RequestParts
ResponseParts
```
