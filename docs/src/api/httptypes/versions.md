```@meta
CurrentModule = HttpTypes
```

# Versions

This page documents [`Version`](@ref), the HTTP protocol version carried by
every [`Request`](@ref) and [`Response`](@ref).

## Using versions

`version(req)` returns one of five constants. They are ordered oldest first,
so you can compare them:

```@repl versions
using HttpTypes
req = Request(Methods.GET, "/");
version(req)
version(req) >= Versions.HTTP_11
string(version(req))
```

```@eval
using HttpTypes, Markdown
rows = ["| `Versions.$k` | `$s` |" for (k, s) in HttpTypes._V_TABLE]
Markdown.parse("| Constant | Text |\n|:--|:--|\n" * join(rows, "\n"))
```

The type only names a version. Which versions a server speaks is up to the
server: Facil speaks HTTP/1.1 and HTTP/1.0.

## Reference

```@docs
Version
Versions
```
