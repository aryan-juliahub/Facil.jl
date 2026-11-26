```@meta
CurrentModule = HttpTypes
```

# Status codes

This page documents [`StatusCode`](@ref), the type of a response's status, and
lists every `StatusCodes` constant. Use it to find the constant for a code, to
build a code that has no constant, or to classify a code.

## Using status codes

Pass a constant to [`Response`](@ref):

```@repl status
using HttpTypes
res = Response(StatusCodes.NOT_FOUND, "no such user");
status(res)
status(res) == 404
string(status(res))
```

An integer works wherever a status is expected next to a body, and for field
assignment. A code without a constant is built with `StatusCode(n)`:

```@repl status
status(Response(404, "no such user"))
res.status = 410;
status(res)
StatusCode(299)
```

!!! note
    `Response(404)` with a single integer argument throws an `ArgumentError`,
    because it could mean "status 404" or "body 404". Write
    `Response(StatusCodes.NOT_FOUND)` for an empty response.

Classify a code with the `is_*` functions:

```@repl status
is_success(StatusCodes.CREATED), is_client_error(StatusCodes.NOT_FOUND), is_server_error(StatusCodes.BAD_GATEWAY)
```

## All constants

```@eval
using HttpTypes, Markdown
rows = ["| $n | `StatusCodes.$k` | $r |" for (n, k, r) in HttpTypes._S_TABLE]
Markdown.parse("| Code | Constant | Reason phrase |\n|:--|:--|:--|\n" * join(rows, "\n"))
```

## Reference

```@docs
StatusCode
StatusCodes
canonical_reason
is_informational
is_success
is_redirection
is_client_error
is_server_error
```

See also [`InvalidStatusCode`](@ref) on the [errors page](errors.md).
