```@meta
CurrentModule = HttpTypes
```

# Headers

This page documents the three header types: [`HeaderName`](@ref),
[`HeaderValue`](@ref) and the multimap [`HeaderMap`](@ref) that holds them. Use
it to read request headers, set response headers, handle repeated headers such
as `Set-Cookie`, and look up the constant for a standard header name.

## Reading headers

`headers(req)` is a `HeaderMap`. Look a header up by constant or by string;
strings match in any case:

```@repl headers
using HttpTypes
req = Request(; uri = "/", headers = ["Content-Type" => "application/json",
                                      "Accept" => "text/html", "Accept" => "application/json"]);
h = headers(req);
h[header.CONTENT_TYPE]
h["content-type"] == "application/json"
get(h, "x-request-id", nothing)
haskey(h, "ACCEPT")
```

Indexing and `get` return the **first** value of a name. A header sent several
times keeps all its values; [`get_all`](@ref) returns them:

```@repl headers
get_all(h, header.ACCEPT)
length(h), keys_len(h)
```

A value is a [`HeaderValue`](@ref), not a `String`. It compares with strings
directly; convert it with [`as_str`](@ref) (or `String`) when you need string
functions:

```@repl headers
v = h[header.CONTENT_TYPE]
v == "application/json"
startswith(as_str(v), "application/")
```

Iterating a map yields `name => value` pairs, one per value:

```@repl headers
for (name, value) in h
    println(name, ": ", value)
end
```

## Writing headers

Pass headers to a constructor as pairs, or change the map in place.
`h[name] = value` replaces, `append!` adds:

```@repl headers
res = Response(StatusCodes.OK, "hi"; headers = [header.CONTENT_TYPE => "text/plain"]);
h = headers(res);
h[header.CACHE_CONTROL] = "no-store";
append!(h, header.SET_COOKIE, "a=1");
append!(h, header.SET_COOKIE, "b=2");
h
delete!(h, header.CACHE_CONTROL);
keys_len(h)
```

Values convert from strings, integers and header names. Names and values are
validated as they go in; a value with a line break can never get into a map:

```@repl headers
h["content-length"] = 2;
h["vary"] = header.ACCEPT_ENCODING;
tryparse(HeaderValue, "evil\r\nx-injected: 1") === nothing
```

For a name that has no constant, write a literal with [`hn"..."`](@ref @hn_str).
It is checked when the code is parsed and costs nothing at run time; the same
goes for [`hv"..."`](@ref @hv_str) values:

```@repl headers
h[hn"x-request-id"] = hv"42";
```

To keep a secret out of logs, mark its value sensitive. `show` then hides it
(but `as_str` and `print` do not):

```@repl headers
h[header.AUTHORIZATION] = set_sensitive(HeaderValue("Bearer abc123"), true);
h[header.AUTHORIZATION]
```

## Standard header names

Every constant in `header`. The constant for a name is its uppercase form with
`-` replaced by `_`.

```@eval
using HttpTypes, Markdown
t = HttpTypes.STANDARD_HEADER_TABLE
rows = ["| `header.$k` | `$s` |" for (k, s) in t]
Markdown.parse("| Constant | Name |\n|:--|:--|\n" * join(rows, "\n"))
```

## Reference: header names

```@docs
HeaderName
header
@hn_str
from_static
from_lowercase
HttpTypes.STANDARD_HEADER_TABLE
HttpTypes.standard_header
HttpTypes.standard_index
```

## Reference: header values

```@docs
HeaderValue
@hv_str
to_str
is_sensitive
set_sensitive
HttpTypes.unchecked
```

`as_str` is documented on the [overview page](index.md#Text-forms).

## Reference: header map

```@docs
HeaderMap
Base.getindex(::HeaderMap, ::Any)
Base.get(::HeaderMap, ::Any, ::Any)
Base.haskey(::HeaderMap, ::Any)
get_all
Base.length(::HeaderMap)
keys_len
Base.keys(::HeaderMap)
Base.values(::HeaderMap)
Base.setindex!(::HeaderMap, ::Any, ::Any)
Base.insert!(::HeaderMap, ::Any, ::Any)
Base.append!(::HeaderMap, ::Any, ::Any)
extend!
remove!
Base.delete!(::HeaderMap, ::Any)
Base.pop!(::HeaderMap, ::Any)
drain!
reserve!
Base.sizehint!(::HeaderMap, ::Integer)
```

## Reference: entries

An entry is a handle on one key of a map, for "look up once, then read or
write" code. Most programs only need [`or_insert!`](@ref).

```@docs
entry
OccupiedEntry
VacantEntry
key
or_insert!
or_insert_with!
insert_entry!
Base.insert!(::VacantEntry, ::Any)
Base.insert!(::OccupiedEntry, ::Any)
insert_mult!
Base.append!(::OccupiedEntry, ::Any)
remove_entry!
remove_entry_mult!
```

See also [`InvalidHeaderName`](@ref), [`InvalidHeaderValue`](@ref),
[`ToStrError`](@ref) and [`MaxSizeReached`](@ref) on the [errors page](errors.md).
