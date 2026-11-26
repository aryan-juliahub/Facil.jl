export Extensions, remove!

"""
    Extensions()

A type map: a collection that holds at most one value per type, keyed by the
value's own type.

Every [`Request`](@ref) and [`Response`](@ref) has one (`extensions(r)`). It
carries data that belongs to a message but is not part of HTTP: a request id, an
authenticated user, a start time. Give each kind of data its own struct type so
that unrelated code cannot collide.

| Call | Effect | Returns |
|:--|:--|:--|
| `insert!(ext, val)` | store `val` under `typeof(val)` | the value it replaced, or `nothing` |
| `get(ext, T)` | | the value of type `T`, or `nothing` |
| `get(ext, T, default)` | | the value, or `default` |
| `ext[T]` | | the value; `KeyError` if absent |
| `haskey(ext, T)` | | `Bool` |
| `get!(ext, T, default)` | store `default` if `T` is absent | the stored value |
| `get!(f, ext, T)` | store `f()` if `T` is absent | the stored value |
| `get!(ext, T)` | store `T()` if `T` is absent | the stored value |
| [`remove!`](@ref)`(ext, T)` | remove | the value, or `nothing` |
| `pop!(ext, T)`, `pop!(ext, T, default)` | remove | the value; `KeyError` or `default` if absent |
| `delete!(ext, T)` | remove | `ext` |
| `empty!(ext)` | remove everything | `ext` |
| `isempty(ext)`, `length(ext)` | | |
| `merge!(ext, other)` | copy `other`'s values in, replacing same-typed ones | `ext` |
| `copy(ext)` | | a new map sharing the same values |

# Notes
- The key is the exact concrete type: a value stored as `Int32` is not found by
  `get(ext, Integer)`.
- The values of `get!` are converted to `T`.
- The map allocates nothing until the first insert, so an unused `Extensions`
  is free.
- `show` lists the stored types only, never the values.
- Not thread-safe; do not change one map from two tasks at once.

# Examples
```jldoctest
julia> struct RequestId
           value::Int
       end

julia> ext = Extensions();

julia> insert!(ext, RequestId(7)) === nothing
true

julia> get(ext, RequestId)
RequestId(7)

julia> insert!(ext, RequestId(8))
RequestId(7)

julia> get(ext, String) === nothing, get(ext, String, "none")
(true, "none")

julia> haskey(ext, RequestId), length(ext)
(true, 1)

julia> remove!(ext, RequestId), isempty(ext)
(RequestId(8), true)
```
"""
mutable struct Extensions
    map::Union{Nothing,IdDict{DataType,Any}}
end
Extensions() = Extensions(nothing)

@inline function _x_map!(e::Extensions)
    m = e.map
    m === nothing || return m
    return e.map = IdDict{DataType,Any}()
end

struct _XMissing end
const _X_MISSING = _XMissing()

"""
    insert!(ext::Extensions, val)

Store `val`, keyed by `typeof(val)`, replacing any value of that type.

# Returns
The value that was replaced, or `nothing` if there was none.

# Examples
```jldoctest
julia> ext = Extensions();

julia> insert!(ext, 1) === nothing
true

julia> insert!(ext, 2)
1

julia> ext[Int]
2
```
"""
function Base.insert!(e::Extensions, val::T) where {T}
    m = _x_map!(e)
    old = get(m, T, _X_MISSING)
    m[T] = val
    return old === _X_MISSING ? nothing : old::T
end

"""
    get(ext::Extensions, T::Type)
    get(ext::Extensions, T::Type, default)

The stored value of type `T`, or `default` (`nothing` when not given) if there
is none. `ext[T]` throws a `KeyError` instead, and `haskey(ext, T)` tests for
presence.

# Examples
```jldoctest
julia> ext = Extensions(); insert!(ext, "trace-1");

julia> get(ext, String)
"trace-1"

julia> get(ext, Int) === nothing, get(ext, Int, 0)
(true, 0)
```
"""
function Base.get(e::Extensions, ::Type{T}, default) where {T}
    m = e.map
    m === nothing && return default
    v = get(m, T, _X_MISSING)
    return v === _X_MISSING ? default : v::T
end
Base.get(e::Extensions, ::Type{T}) where {T} = get(e, T, nothing)

function Base.getindex(e::Extensions, ::Type{T}) where {T}
    v = get(e, T, _X_MISSING)
    v === _X_MISSING && throw(KeyError(T))
    return v::T
end

Base.haskey(e::Extensions, ::Type{T}) where {T} = e.map !== nothing && haskey(e.map, T)

"""
    get!(ext::Extensions, T::Type, default)
    get!(f, ext::Extensions, T::Type)
    get!(ext::Extensions, T::Type)

The stored value of type `T`; if there is none, store one first: `default`,
`f()` or `T()`, converted to `T`.

# Examples
```jldoctest
julia> ext = Extensions();

julia> push!(get!(ext, Vector{String}), "first");

julia> push!(get!(ext, Vector{String}), "second");

julia> ext[Vector{String}]
2-element Vector{String}:
 "first"
 "second"

julia> get!(ext, Int, 5), get!(ext, Int, 9)
(5, 5)
```
"""
function Base.get!(f::Base.Callable, e::Extensions, ::Type{T}) where {T}
    m = _x_map!(e)
    v = get(m, T, _X_MISSING)
    v === _X_MISSING || return v::T
    new = convert(T, f())::T
    m[T] = new
    return new
end
Base.get!(e::Extensions, ::Type{T}, default) where {T} = get!(() -> default, e, T)
Base.get!(e::Extensions, ::Type{T}) where {T} = get!(T, e, T)

function remove!(e::Extensions, ::Type{T}) where {T}
    m = e.map
    m === nothing && return nothing
    v = pop!(m, T, _X_MISSING)
    return v === _X_MISSING ? nothing : v::T
end

function Base.pop!(e::Extensions, ::Type{T}, default) where {T}
    m = e.map
    m === nothing && return default
    v = pop!(m, T, _X_MISSING)
    return v === _X_MISSING ? default : v::T
end
function Base.pop!(e::Extensions, ::Type{T}) where {T}
    v = pop!(e, T, _X_MISSING)
    v === _X_MISSING && throw(KeyError(T))
    return v::T
end

function Base.delete!(e::Extensions, ::Type{T}) where {T}
    e.map === nothing || delete!(e.map, T)
    return e
end

function Base.empty!(e::Extensions)
    e.map === nothing || empty!(e.map)
    return e
end
Base.isempty(e::Extensions) = e.map === nothing || isempty(e.map)
Base.length(e::Extensions) = e.map === nothing ? 0 : length(e.map)

function Base.merge!(e::Extensions, other::Extensions)
    o = other.map
    (o === nothing || isempty(o)) && return e
    merge!(_x_map!(e), o)
    return e
end

Base.copy(e::Extensions) = Extensions(e.map === nothing ? nothing : copy(e.map))

function Base.show(io::IO, e::Extensions)
    print(io, "Extensions(")
    if e.map !== nothing
        join(io, keys(e.map), ", ")
    end
    print(io, ")")
end
