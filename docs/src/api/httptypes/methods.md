```@meta
CurrentModule = HttpTypes
```

# Methods

This page documents [`HttpMethod`](@ref), the type of a request's method, and
the `Methods` constants. Use it when you branch on the method of a request or
need to know which methods count as safe or idempotent.

## Using methods

`method(req)` returns an `HttpMethod`. Compare it with a constant or with a
string:

```@repl methods
using HttpTypes
req = Request(; method = "POST", uri = "/users");
method(req) == Methods.POST
method(req) == "POST"
```

The ten standard methods are constants. Any other valid token is an extension
method and works the same way:

```@repl methods
purge = HttpMethod("PURGE")
purge == "PURGE", is_safe(purge)
```

Methods are case-sensitive, as HTTP requires. `"get"` is a valid token, but it
is not `GET`:

```@repl methods
HttpMethod("get") == Methods.GET
```

The constants and their properties:

```@eval
using HttpTypes, Markdown
rows = ["| `Methods.$n` | `$n` | $(is_safe(getfield(Methods, Symbol(n))) ? "yes" : "no") | $(is_idempotent(getfield(Methods, Symbol(n))) ? "yes" : "no") |" for n in HttpTypes._M_NAMES]
Markdown.parse("| Constant | Token | Safe | Idempotent |\n|:--|:--|:--|:--|\n" * join(rows, "\n"))
```

## Reference

```@docs
HttpMethod
Methods
is_safe
is_idempotent
```

See also [`InvalidMethod`](@ref) on the [errors page](errors.md).
