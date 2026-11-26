```@meta
CurrentModule = HttpTypes
```

# Extensions

This page documents [`Extensions`](@ref), the typed side-channel that every
[`Request`](@ref) and [`Response`](@ref) carries. Use it to attach data to a
message that is not part of HTTP, such as a request id or the authenticated
user, and read it back later by type.

## Using extensions

An `Extensions` holds at most one value per type. The type is the key, so
define a small struct for each kind of data:

```@repl ext
using HttpTypes
struct RequestId
    value::Int
end
struct User
    name::String
end
req = Request(Methods.GET, "/account");
insert!(extensions(req), RequestId(7));
insert!(extensions(req), User("ada"));
get(extensions(req), User)
get(extensions(req), RequestId).value
```

`get` returns `nothing` (or a default you pass) when no value of that type is
stored; indexing throws instead:

```@repl ext
struct Session end
get(extensions(req), Session)
get(extensions(req), Session, "fallback")
haskey(extensions(req), Session)
```

`get!` stores a value on first use, which suits per-request scratch data:

```@repl ext
push!(get!(extensions(req), Vector{String}), "checked auth");
push!(get!(extensions(req), Vector{String}), "loaded user");
extensions(req)[Vector{String}]
```

Extensions can also be given at construction, as a tuple of values:

```@repl ext
r = Request(; uri = "/x", extensions = (RequestId(1), User("bob")));
length(extensions(r))
```

!!! note
    The key is the exact type of the value. A value stored as `Int32` is not
    found by `get(ext, Integer)` or `get(ext, Int)`.

## Reference

```@docs
Extensions
Base.insert!(::Extensions, ::Any)
Base.get(::Extensions, ::Type, ::Any)
Base.get!(::Base.Callable, ::Extensions, ::Type)
```

[`remove!`](@ref) is documented with the header map functions.
