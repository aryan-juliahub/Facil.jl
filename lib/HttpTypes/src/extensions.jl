export Extensions, remove!

"""
    Extensions()

A type map: holds at most one value per type, keyed by `typeof(value)`.

    insert!(ext, val)      # returns the previous value of that type, or nothing
    get(ext, T)            # the value of type T, or nothing
    get(ext, T, default); ext[T]; haskey(ext, T)
    get!(ext, T, default); get!(f, ext, T); get!(ext, T)  # T() when missing
    remove!(ext, T)        # removes and returns the value, or nothing
    pop!(ext, T[, default]); delete!(ext, T)
    empty!, isempty, length, merge!(ext, other), copy

`copy` copies the map, not the values. The map is allocated on first insert.
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

function Base.insert!(e::Extensions, val::T) where {T}
    m = _x_map!(e)
    old = get(m, T, _X_MISSING)
    m[T] = val
    return old === _X_MISSING ? nothing : old::T
end

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
