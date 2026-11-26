export HeaderMap, MaxSizeReached, get_all, keys_len, remove!, drain!, extend!, reserve!,
    entry, OccupiedEntry, VacantEntry, key, or_insert!, or_insert_with!, insert_entry!,
    insert_mult!, remove_entry!, remove_entry_mult!

"""
    MaxSizeReached <: HttpError

Thrown when a [`HeaderMap`](@ref) would grow past its limit: more than 24,576
distinct names, or a capacity above that asked of `HeaderMap{T}(capacity)`,
`sizehint!` or [`reserve!`](@ref). The message is `max size reached`.

# Examples
```jldoctest
julia> HeaderMap{HeaderValue}(40_000)
ERROR: max size reached
[...]
```
"""
struct MaxSizeReached <: HttpError end
Base.showerror(io::IO, ::MaxSizeReached) = print(io, "max size reached")

const _H_MAX_SIZE = 1 << 15
const _H_MAX_KEYS = _H_MAX_SIZE - _H_MAX_SIZE ÷ 4

"""
    HeaderMap()
    HeaderMap(pairs::Pair...)
    HeaderMap(itr)
    HeaderMap{T}()
    HeaderMap{T}(capacity::Integer)
    HeaderMap{T}(pairs::Pair...)
    HeaderMap{T}(itr)

A multimap from [`HeaderName`](@ref) to values of type `T`: one name can hold
several values, as HTTP headers do. `HeaderMap()` is `HeaderMap{HeaderValue}()`,
the type [`Request`](@ref) and [`Response`](@ref) use.

# Arguments
- `pairs`, `itr`: `name => value` pairs to add, in order, as with
  [`extend!`](@ref): a name given twice ends up with two values.
- `capacity::Integer`: room to reserve for this many values.

Wherever a function takes a key it may be a `HeaderName`, a string in any case,
or bytes; wherever it takes a value, anything that converts to `T` (for
[`HeaderValue`](@ref): strings, bytes, integers, header names).

# Throws
- [`InvalidHeaderName`](@ref), [`InvalidHeaderValue`](@ref) for a pair that does
  not convert.
- [`MaxSizeReached`](@ref) for a `capacity` over 24,576, or when the map would
  hold more than 24,576 distinct names.

# Reading

| Call | Result |
|:--|:--|
| `h[key]` | first value of `key`; `KeyError` if absent |
| `get(h, key, default)`, `get(f, h, key)` | first value, or `default` / `f()` |
| `haskey(h, key)` | whether `key` has a value |
| [`get_all`](@ref)`(h, key)` | view of every value of `key` |
| `length(h)` | number of values, repeated names included |
| [`keys_len`](@ref)`(h)` | number of distinct names |
| `isempty(h)` | whether there are no values |
| `keys(h)`, `values(h)` | each distinct name once; every value |
| `for (name, value) in h` | every pair; `eltype` is `Pair{HeaderName,T}` |

A lookup with a string that is not a valid header name finds nothing; it does
not throw.

# Writing

| Call | Effect | Returns |
|:--|:--|:--|
| `h[key] = value` | set `key` to the single `value` | |
| `insert!(h, key, value)` | the same | first replaced value, or `nothing` |
| `append!(h, key, value)` | add a value, keeping existing ones | whether `key` was present |
| [`extend!`](@ref)`(h, itr)` | append many pairs | `h` |
| [`remove!`](@ref)`(h, key)` | remove every value of `key` | first value, or `nothing` |
| `delete!(h, key)` | the same | `h` |
| `pop!(h, key[, default])` | the same | first value; `KeyError` or `default` if absent |
| [`drain!`](@ref)`(h)` | remove everything | the removed pairs |
| `empty!(h)` | remove everything | `h` |
| [`entry`](@ref)`(h, key)` | in-place work on one key | an entry |

Also `copy(h)` (the values themselves are shared), `h1 == h2` (same names with
the same values in the same order per name; the order of names does not
matter), `sizehint!` and [`reserve!`](@ref).

# Order
Iteration yields names in the order they were first added, with all values of
one name together, in the order they were added. Removing a name moves the last
name into its place, so removal does not keep the order of the remaining names.

# Examples
```jldoctest
julia> h = HeaderMap("Content-Type" => "text/html", "Set-Cookie" => "a=1", "Set-Cookie" => "b=2")
HeaderMap(hn"content-type" => hv"text/html", hn"set-cookie" => hv"a=1", hn"set-cookie" => hv"b=2")

julia> h[header.CONTENT_TYPE]
hv"text/html"

julia> h["set-cookie"], length(get_all(h, "set-cookie"))
(hv"a=1", 2)

julia> length(h), keys_len(h)
(3, 2)

julia> h["x-request-id"] = "42";

julia> get(h, "x-missing", nothing) === nothing
true

julia> [as_str(name) for name in keys(h)]
3-element Vector{String}:
 "content-type"
 "set-cookie"
 "x-request-id"
```
"""
mutable struct HeaderMap{T}
    # Parallel vectors; the values of one name are contiguous.
    const names::Vector{HeaderName}
    const values::Vector{T}
    nkeys::Int
    HeaderMap{T}() where {T} = new{T}(HeaderName[], T[], 0)
    global _h_map_unchecked(names::Vector{HeaderName}, values::Vector{T}, nkeys::Int) where {T} =
        new{T}(names, values, nkeys)
end

HeaderMap() = HeaderMap{HeaderValue}()

function _h_check_capacity(n::Integer)
    (n < 0 || n > _H_MAX_SIZE) && throw(MaxSizeReached())
    raw = n + n ÷ 3
    (raw > _H_MAX_SIZE || (raw > 0 && nextpow(2, raw) > _H_MAX_SIZE)) && throw(MaxSizeReached())
    return nothing
end

function HeaderMap{T}(capacity::Integer) where {T}
    _h_check_capacity(capacity)
    h = HeaderMap{T}()
    sizehint!(h.names, capacity)
    sizehint!(h.values, capacity)
    return h
end

HeaderMap{T}(itr) where {T} = extend!(HeaderMap{T}(), itr)
HeaderMap{T}(ps::Pair...) where {T} = extend!(HeaderMap{T}(), ps)
HeaderMap(itr) = HeaderMap{HeaderValue}(itr)
HeaderMap(ps::Pair...) = HeaderMap{HeaderValue}(ps)

"""
    sizehint!(h::HeaderMap, n::Integer) -> h

Reserve room for `n` values in total.

# Throws
- [`MaxSizeReached`](@ref) if `n` is negative or over 24,576.

See also [`reserve!`](@ref).
"""
function Base.sizehint!(h::HeaderMap, n::Integer)
    _h_check_capacity(n)
    sizehint!(h.names, n)
    sizehint!(h.values, n)
    return h
end

"""
    reserve!(h::HeaderMap, additional::Integer) -> h

Reserve room for `additional` more names, so that adding them does not
reallocate. The contents do not change.

# Throws
- [`MaxSizeReached`](@ref) if `additional` is negative, or the map would then
  have room for more than 24,576 names.

# Examples
```jldoctest
julia> h = reserve!(HeaderMap(), 16);

julia> isempty(h)
true

julia> reserve!(h, 40_000)
ERROR: max size reached
[...]
```
"""
function reserve!(h::HeaderMap, additional::Integer)
    (additional < 0 || additional > _H_MAX_SIZE) && throw(MaxSizeReached())
    _h_check_capacity(h.nkeys + additional)
    sizehint!(h.names, length(h.names) + additional)
    sizehint!(h.values, length(h.values) + additional)
    return h
end

Base.copy(h::HeaderMap) = _h_map_unchecked(copy(h.names), copy(h.values), h.nkeys)

"""
    length(h::HeaderMap) -> Int

The number of values in the map. A name with three values counts three times;
[`keys_len`](@ref) counts names.

# Examples
```jldoctest
julia> length(HeaderMap("accept" => "text/html", "accept" => "text/plain"))
2
```
"""
Base.length(h::HeaderMap) = length(h.values)
"""
    keys_len(h::HeaderMap) -> Int

The number of distinct names in the map. `length(h)` counts values instead.

# Examples
```jldoctest
julia> h = HeaderMap("accept" => "text/html", "accept" => "text/plain", "host" => "example.com");

julia> keys_len(h), length(h)
(2, 3)
```
"""
keys_len(h::HeaderMap) = h.nkeys
Base.isempty(h::HeaderMap) = isempty(h.values)
function Base.empty!(h::HeaderMap)
    empty!(h.names)
    empty!(h.values)
    h.nkeys = 0
    return h
end

# ---- lookup ----

@inline _h_to_name(k::HeaderName) = k
@inline _h_to_name(k) = HeaderName(k)

# Index of the first value stored under the key, or 0.
@inline function _h_find(h::HeaderMap, k::HeaderName)
    names = h.names
    id = getfield(k, :id)
    if id != 0x0000
        @inbounds for i in eachindex(names)
            getfield(names[i], :id) == id && return i
        end
    else
        s = as_str(k)
        @inbounds for i in eachindex(names)
            e = names[i]
            getfield(e, :id) == 0x0000 && as_str(e) == s && return i
        end
    end
    return 0
end

# Strings match in any case without building a HeaderName; invalid ones match nothing.
function _h_find(h::HeaderMap, k::StrLike)
    names = h.names
    n = sizeof(k)
    GC.@preserve k begin
        p = _ptr(k)
        id = _h_std_lookup(p, n, _H_CHARS)
        if id != 0x0000
            @inbounds for i in eachindex(names)
                getfield(names[i], :id) == id && return i
            end
        else
            @inbounds for i in eachindex(names)
                e = names[i]
                s = as_str(e)
                getfield(e, :id) == 0x0000 && sizeof(s) == n && _h_lc_eq(p, n, s, _H_CHARS) && return i
            end
        end
    end
    return 0
end
_h_find(h::HeaderMap, k::AbstractString) = _h_find(h, String(k))
function _h_find(h::HeaderMap, k::AbstractVector{UInt8})
    name = tryparse(HeaderName, k)
    return name === nothing ? 0 : _h_find(h, name)
end

# Index of the last value in the run that starts at `i`.
@inline function _h_run_end(h::HeaderMap, i::Int)
    names = h.names
    k = @inbounds names[i]
    j = i
    @inbounds while j < length(names) && names[j+1] == k
        j += 1
    end
    return j
end

"""
    haskey(h::HeaderMap, key) -> Bool

Whether `key` has at least one value. `key` is a [`HeaderName`](@ref), a string
in any case, or bytes; an invalid name is simply absent.

# Examples
```jldoctest
julia> h = HeaderMap("Content-Type" => "text/html");

julia> haskey(h, "content-type"), haskey(h, header.CONTENT_TYPE), haskey(h, "not a name")
(true, true, false)
```
"""
Base.haskey(h::HeaderMap, k) = _h_find(h, k) != 0

"""
    get(h::HeaderMap, key, default)
    get(f, h::HeaderMap, key)

The first value stored under `key`, or `default` (or `f()`) when there is none.

`key` is a [`HeaderName`](@ref), a string in any case, or bytes. A string is
matched without building a `HeaderName`, and one that is not a valid name gives
`default`; nothing is thrown. Use [`get_all`](@ref) for every value of a
repeated header.

# Examples
```jldoctest
julia> h = HeaderMap("Content-Type" => "text/html");

julia> get(h, "content-type", nothing)
hv"text/html"

julia> get(h, header.ACCEPT, hv"*/*")
hv"*/*"

julia> get(() -> "none", h, "x-missing")
"none"
```
"""
@inline function Base.get(h::HeaderMap, k, default)
    i = _h_find(h, k)
    return i == 0 ? default : @inbounds h.values[i]
end

function Base.get(f::Base.Callable, h::HeaderMap, k)
    i = _h_find(h, k)
    return i == 0 ? f() : @inbounds h.values[i]
end

"""
    getindex(h::HeaderMap, key)
    h[key]

The first value stored under `key`.

# Throws
- `KeyError` if `key` has no value (also for a string that is not a valid
  header name).

# Examples
```jldoctest
julia> h = HeaderMap("accept" => "text/html", "accept" => "text/plain");

julia> h["Accept"]
hv"text/html"

julia> h["host"]
ERROR: KeyError: key "host" not found
[...]
```
"""
@inline function Base.getindex(h::HeaderMap, k)
    i = _h_find(h, k)
    i == 0 && throw(KeyError(k))
    return @inbounds h.values[i]
end

"""
    get_all(h::HeaderMap, key) -> AbstractVector

Every value stored under `key`, in the order they were added. Empty when the
key is absent.

# Returns
A view into the map's storage, not a copy: reading it is free, and assigning to
an element changes the map. It is only valid until the map is next changed;
`collect` it to keep the values.

# Examples
```jldoctest
julia> h = HeaderMap("set-cookie" => "a=1", "set-cookie" => "b=2");

julia> [as_str(v) for v in get_all(h, "Set-Cookie")]
2-element Vector{String}:
 "a=1"
 "b=2"

julia> isempty(get_all(h, "accept"))
true
```
"""
@inline function get_all(h::HeaderMap, k)
    i = _h_find(h, k)
    return i == 0 ? view(h.values, 1:0) : view(h.values, i:_h_run_end(h, i))
end

# ---- mutation ----

@inline function _h_push_new!(h::HeaderMap, k::HeaderName, v)
    h.nkeys >= _H_MAX_KEYS && throw(MaxSizeReached())
    push!(h.names, k)
    push!(h.values, v)
    h.nkeys += 1
    return nothing
end

# Keeps the value at `i` as `val` and drops the rest of its run.
function _h_replace_run!(h::HeaderMap, i::Int, val)
    old = @inbounds h.values[i]
    j = _h_run_end(h, i)
    if j > i
        deleteat!(h.names, i+1:j)
        deleteat!(h.values, i+1:j)
    end
    @inbounds h.values[i] = val
    return old
end

"""
    insert!(h::HeaderMap, key, value)

Set `key` to the single `value`, replacing every value it had. The name keeps
its position in the map; a new name goes at the end.

# Returns
The first value that was replaced, or `nothing` if the key was absent.
`h[key] = value` does the same and returns `h`.

# Throws
- [`InvalidHeaderName`](@ref) if `key` is not a valid name.
- [`InvalidHeaderValue`](@ref) if `value` does not convert.
- [`MaxSizeReached`](@ref) if the map already holds 24,576 names and `key` is new.

# Examples
```jldoctest
julia> h = HeaderMap("accept" => "text/html", "accept" => "text/plain");

julia> insert!(h, "Accept", "*/*")
hv"text/html"

julia> h
HeaderMap(hn"accept" => hv"*/*")

julia> insert!(h, "host", "example.com") === nothing
true
```

See also [`append!`](@ref Base.append!(::HeaderMap, ::Any, ::Any)).
"""
@inline function Base.insert!(h::HeaderMap{T}, k, v) where {T}
    name = _h_to_name(k)
    val = convert(T, v)
    i = _h_find(h, name)
    if i == 0
        _h_push_new!(h, name, val)
        return nothing
    end
    return _h_replace_run!(h, i, val)
end

"""
    setindex!(h::HeaderMap, value, key)
    h[key] = value

Set `key` to the single `value`, replacing every value it had. The same as
[`insert!`](@ref Base.insert!(::HeaderMap, ::Any, ::Any)) without the returned
old value; throws the same errors.

# Examples
```jldoctest
julia> h = HeaderMap();

julia> h[header.CONTENT_TYPE] = "application/json";

julia> h["content-length"] = 2;

julia> h
HeaderMap(hn"content-type" => hv"application/json", hn"content-length" => hv"2")
```
"""
Base.setindex!(h::HeaderMap, v, k) = (insert!(h, k, v); h)

"""
    append!(h::HeaderMap, key, value) -> Bool

Add `value` under `key`, after any values the key already has.

# Returns
`true` if the key was already present, `false` if this is its first value.

# Throws
- [`InvalidHeaderName`](@ref), [`InvalidHeaderValue`](@ref) if `key` or `value`
  does not convert.
- [`MaxSizeReached`](@ref) if the map already holds 24,576 names and `key` is new.

# Examples
```jldoctest
julia> h = HeaderMap();

julia> append!(h, "set-cookie", "a=1")
false

julia> append!(h, "set-cookie", "b=2")
true

julia> h
HeaderMap(hn"set-cookie" => hv"a=1", hn"set-cookie" => hv"b=2")
```
"""
@inline function Base.append!(h::HeaderMap{T}, k, v) where {T}
    name = _h_to_name(k)
    val = convert(T, v)
    i = _h_find(h, name)
    if i == 0
        _h_push_new!(h, name, val)
        return false
    end
    _h_append_at!(h, name, val, _h_run_end(h, i))
    return true
end

function _h_append_at!(h::HeaderMap, name::HeaderName, val, j::Int)
    if j == length(h.names)
        push!(h.names, name)
        push!(h.values, val)
    else
        insert!(h.names, j + 1, name)
        insert!(h.values, j + 1, val)
    end
    return nothing
end

# Removes the run i:j. The last name takes the freed place, as a swap-remove does.
function _h_remove_run!(h::HeaderMap, i::Int, j::Int)
    n = length(h.names)
    deleteat!(h.names, i:j)
    deleteat!(h.values, i:j)
    h.nkeys -= 1
    if j < n
        m = length(h.names)
        last = h.names[m]
        s = m
        while s > 1 && h.names[s-1] == last
            s -= 1
        end
        if s > i
            tailnames = splice!(h.names, s:m)
            tailvalues = splice!(h.values, s:m)
            splice!(h.names, i:i-1, tailnames)
            splice!(h.values, i:i-1, tailvalues)
        end
    end
    return nothing
end

"""
    remove!(h::HeaderMap, key)
    remove!(e::OccupiedEntry)
    remove!(ext::Extensions, T::Type)

Remove something and return it, or `nothing` if it was not there.

- `remove!(h, key)` removes every value of `key` from a [`HeaderMap`](@ref) and
  returns the first one. The last name in the map moves into the freed place.
  A key that is not a valid header name is simply absent.
- `remove!(e)` removes the key of an [`OccupiedEntry`](@ref) and returns its first
  value.
- `remove!(ext, T)` removes the value of type `T` from [`Extensions`](@ref) and
  returns it.

`delete!` does the same and returns the collection; `pop!` throws a `KeyError`
when nothing was there.

# Examples
```jldoctest
julia> h = HeaderMap("accept" => "text/html", "accept" => "text/plain", "host" => "example.com");

julia> remove!(h, "Accept")
hv"text/html"

julia> h
HeaderMap(hn"host" => hv"example.com")

julia> remove!(h, "accept") === nothing
true

julia> ext = Extensions(); insert!(ext, 42);

julia> remove!(ext, Int), remove!(ext, Int)
(42, nothing)
```
"""
function remove! end

function remove!(h::HeaderMap, k)
    i = _h_find(h, k)
    i == 0 && return nothing
    old = @inbounds h.values[i]
    _h_remove_run!(h, i, _h_run_end(h, i))
    return old
end

"""
    delete!(h::HeaderMap, key) -> h

Remove every value of `key`, if any, and return the map. Like
[`remove!`](@ref) without the removed value.

# Examples
```jldoctest
julia> delete!(HeaderMap("accept" => "*/*", "host" => "example.com"), "accept")
HeaderMap(hn"host" => hv"example.com")
```
"""
Base.delete!(h::HeaderMap, k) = (remove!(h, k); h)
"""
    pop!(h::HeaderMap, key)
    pop!(h::HeaderMap, key, default)

Remove every value of `key` and return the first one.

# Throws
- `KeyError` if the key is absent and no `default` is given; with `default`,
  that is returned instead.

# Examples
```jldoctest
julia> h = HeaderMap("accept" => "*/*");

julia> pop!(h, "accept")
hv"*/*"

julia> pop!(h, "accept", nothing) === nothing
true
```
"""
function Base.pop!(h::HeaderMap, k)
    i = _h_find(h, k)
    i == 0 && throw(KeyError(k))
    old = @inbounds h.values[i]
    _h_remove_run!(h, i, _h_run_end(h, i))
    return old
end
function Base.pop!(h::HeaderMap, k, default)
    i = _h_find(h, k)
    i == 0 && return default
    old = @inbounds h.values[i]
    _h_remove_run!(h, i, _h_run_end(h, i))
    return old
end

"""
    drain!(h::HeaderMap{T}) -> Vector{Pair{Union{Nothing,HeaderName},T}}

Empty the map and return what it held.

# Returns
One pair per value, in iteration order. The first value of each name carries
the name; further values of the same name carry `nothing` in its place (as the
crate's `drain` does). [`extend!`](@ref) accepts this shape back.

# Examples
```jldoctest
julia> h = HeaderMap("accept" => "text/html", "accept" => "text/plain", "host" => "example.com");

julia> pairs = drain!(h);

julia> [first(p) for p in pairs]
3-element Vector{Union{Nothing, HeaderName}}:
 hn"accept"
 nothing
 hn"host"

julia> isempty(h)
true
```
"""
function drain!(h::HeaderMap{T}) where {T}
    out = Vector{Pair{Union{HeaderName,Nothing},T}}(undef, length(h))
    names = h.names
    for i in eachindex(names)
        first = i == 1 || names[i] != names[i-1]
        out[i] = (first ? names[i] : nothing) => h.values[i]
    end
    empty!(h)
    return out
end

_h_optional_keys(::Type{<:Pair{Union{Nothing,HeaderName}}}) = true
_h_optional_keys(::Type{<:Tuple{Union{Nothing,HeaderName},Any}}) = true
_h_optional_keys(::Type) = false

"""
    extend!(h::HeaderMap, itr) -> h

Add every `key => value` pair of `itr` to the map.

# Arguments
- `itr`: an iterable of pairs (or 2-tuples). Each pair is added as with
  `append!`: values go after those the name already has.

When the element type of `itr` has keys typed `Union{Nothing,HeaderName}` (what
[`drain!`](@ref) returns), the crate's `extend` rule applies instead: a pair
with a name **replaces** the values of that name, and a pair whose key is
`nothing` appends to the name before it.

# Throws
- [`InvalidHeaderName`](@ref), [`InvalidHeaderValue`](@ref),
  [`MaxSizeReached`](@ref), as for `append!`. Pairs before the bad one have
  already been added.
- `ArgumentError` if a drained sequence starts with a `nothing` key.

# Examples
```jldoctest
julia> h = HeaderMap("accept" => "text/html");

julia> extend!(h, ["accept" => "text/plain", "host" => "example.com"])
HeaderMap(hn"accept" => hv"text/html", hn"accept" => hv"text/plain", hn"host" => hv"example.com")

julia> other = HeaderMap("accept" => "*/*");

julia> extend!(other, drain!(h))
HeaderMap(hn"accept" => hv"text/html", hn"accept" => hv"text/plain", hn"host" => hv"example.com")
```
"""
function extend!(h::HeaderMap{T}, itr) where {T}
    if _h_optional_keys(eltype(itr))
        idx = 0
        for (k, v) in itr
            if k === nothing
                idx == 0 && throw(ArgumentError("expected a header name, but got nothing"))
                _h_append_at!(h, h.names[idx], convert(T, v), _h_run_end(h, idx))
            else
                val = convert(T, v)
                idx = _h_find(h, k)
                if idx == 0
                    _h_push_new!(h, k, val)
                    idx = length(h.names)
                else
                    _h_replace_run!(h, idx, val)
                end
            end
        end
    else
        for (k, v) in itr
            append!(h, k, v)
        end
    end
    return h
end

# ---- iteration ----

Base.eltype(::Type{HeaderMap{T}}) where {T} = Pair{HeaderName,T}
Base.IteratorSize(::Type{<:HeaderMap}) = Base.HasLength()
@inline function Base.iterate(h::HeaderMap, i::Int=1)
    i > length(h.values) && return nothing
    return (@inbounds(h.names[i]) => @inbounds(h.values[i]), i + 1)
end

"""
    values(h::HeaderMap) -> AbstractVector

Every value in iteration order, repeated names included.

The result is a view into the map's storage: assigning to an element changes
the map, and the view is only valid until the map is next changed.

# Examples
```jldoctest
julia> h = HeaderMap("accept" => "text/html", "host" => "example.com");

julia> [as_str(v) for v in values(h)]
2-element Vector{String}:
 "text/html"
 "example.com"
```
"""
Base.values(h::HeaderMap) = view(h.values, 1:length(h.values))

struct HeaderKeys{T}
    map::HeaderMap{T}
end
"""
    keys(h::HeaderMap)

An iterator over the distinct names, each once, in iteration order. Its
`length` is [`keys_len`](@ref)`(h)`.

# Examples
```jldoctest
julia> h = HeaderMap("accept" => "text/html", "accept" => "text/plain", "host" => "example.com");

julia> collect(keys(h))
2-element Vector{HeaderName}:
 hn"accept"
 hn"host"
```
"""
Base.keys(h::HeaderMap) = HeaderKeys(h)
Base.eltype(::Type{<:HeaderKeys}) = HeaderName
Base.length(k::HeaderKeys) = k.map.nkeys
function Base.iterate(k::HeaderKeys, i::Int=1)
    names = k.map.names
    @inbounds while i <= length(names) && i > 1 && names[i] == names[i-1]
        i += 1
    end
    i > length(names) && return nothing
    return (@inbounds(names[i]), i + 1)
end

function Base.:(==)(a::HeaderMap, b::HeaderMap)
    length(a) == length(b) || return false
    for k in keys(a)
        get_all(a, k) == get_all(b, k) || return false
    end
    return true
end

function Base.show(io::IO, h::HeaderMap)
    print(io, "HeaderMap(")
    for (i, (k, v)) in enumerate(h)
        i > 1 && print(io, ", ")
        show(io, k)
        print(io, " => ")
        show(io, v)
    end
    print(io, ")")
end

# ---- entry API ----

"""
    OccupiedEntry{T}

A key that is present in a [`HeaderMap`](@ref), returned by [`entry`](@ref).

| Call | Effect | Returns |
|:--|:--|:--|
| [`key`](@ref)`(e)` | | the `HeaderName` |
| `e[]` | | the first value |
| `e[] = v` | replace the first value only | `e` |
| `values(e)`, `for v in e`, `length(e)` | | all values (a view) |
| `insert!(e, v)` | make `v` the only value | the old first value |
| [`insert_mult!`](@ref)`(e, v)` | make `v` the only value | all old values |
| `append!(e, v)` | add `v` after the others | `nothing` |
| [`remove!`](@ref)`(e)` | remove the key | the first value |
| [`remove_entry!`](@ref)`(e)` | remove the key | `(name, first value)` |
| [`remove_entry_mult!`](@ref)`(e)` | remove the key | `(name, all values)` |

An entry remembers a position in the map. It is stale once the map is changed
through anything but this entry; get a new one with `entry` then. After a
`remove...` call the entry must not be used again.

# Examples
```jldoctest
julia> h = HeaderMap("accept" => "text/html", "accept" => "text/plain");

julia> e = entry(h, "accept");

julia> key(e), e[], length(e)
(hn"accept", hv"text/html", 2)

julia> e[] = "application/json";

julia> h
HeaderMap(hn"accept" => hv"application/json", hn"accept" => hv"text/plain")
```
"""
struct OccupiedEntry{T}
    map::HeaderMap{T}
    key::HeaderName
    index::Int
end

"""
    VacantEntry{T}

A key that is absent from a [`HeaderMap`](@ref), returned by [`entry`](@ref).

| Call | Effect | Returns |
|:--|:--|:--|
| [`key`](@ref)`(e)` | | the `HeaderName` |
| `insert!(e, v)` | add the key with value `v` | the stored value |
| [`insert_entry!`](@ref)`(e, v)` | the same | the new [`OccupiedEntry`](@ref) |
| [`or_insert!`](@ref)`(e, default)` | the same as `insert!` | the stored value |

Inserting throws [`InvalidHeaderValue`](@ref) if `v` does not convert and
[`MaxSizeReached`](@ref) if the map is full. Use an entry once.

# Examples
```jldoctest
julia> h = HeaderMap();

julia> e = entry(h, "x-request-id");

julia> e isa VacantEntry, key(e)
(true, hn"x-request-id")

julia> insert!(e, "42")
hv"42"

julia> h
HeaderMap(hn"x-request-id" => hv"42")
```
"""
struct VacantEntry{T}
    map::HeaderMap{T}
    key::HeaderName
end

"""
    entry(h::HeaderMap{T}, key) -> Union{OccupiedEntry{T},VacantEntry{T}}

Look `key` up once and return a handle for in-place work on it: an
[`OccupiedEntry`](@ref) if the key has a value, a [`VacantEntry`](@ref) if not.

This is the way to "read, then insert or update" with a single lookup;
[`or_insert!`](@ref) covers the common case.

# Throws
- [`InvalidHeaderName`](@ref) if `key` is not a valid name.

# Examples
```jldoctest
julia> h = HeaderMap("accept" => "*/*");

julia> entry(h, "accept") isa OccupiedEntry, entry(h, "host") isa VacantEntry
(true, true)

julia> or_insert!(entry(h, "host"), "example.com")
hv"example.com"

julia> or_insert!(entry(h, "host"), "other.example")
hv"example.com"
```
"""
function entry(h::HeaderMap{T}, k) where {T}
    name = _h_to_name(k)
    i = _h_find(h, name)
    return i == 0 ? VacantEntry{T}(h, name) : OccupiedEntry{T}(h, name, i)
end

"""
    key(e::Union{OccupiedEntry,VacantEntry}) -> HeaderName

The header name an entry stands for (see [`entry`](@ref)).

# Examples
```jldoctest
julia> key(entry(HeaderMap(), "Content-Type"))
hn"content-type"
```
"""
key(e::Union{OccupiedEntry,VacantEntry}) = e.key

"""
    insert_entry!(e::VacantEntry, value) -> OccupiedEntry

Add the entry's key to the map with `value`, and return the
[`OccupiedEntry`](@ref) for it, ready for more work on the same key.

# Throws
- [`InvalidHeaderValue`](@ref) if `value` does not convert;
  [`MaxSizeReached`](@ref) if the map is full.

# Examples
```jldoctest
julia> h = HeaderMap();

julia> e = insert_entry!(entry(h, "set-cookie"), "a=1");

julia> append!(e, "b=2");

julia> h
HeaderMap(hn"set-cookie" => hv"a=1", hn"set-cookie" => hv"b=2")
```
"""
function insert_entry!(e::VacantEntry{T}, v) where {T}
    _h_push_new!(e.map, e.key, convert(T, v))
    return OccupiedEntry{T}(e.map, e.key, length(e.map.names))
end
"""
    insert!(e::VacantEntry, value)

Add the entry's key to the map with `value` and return the stored value
(`value` converted to the map's value type). See [`VacantEntry`](@ref).
"""
Base.insert!(e::VacantEntry, v) = insert_entry!(e, v)[]

"""
    or_insert!(e::Union{OccupiedEntry,VacantEntry}, default)

The first value of the entry's key, inserting `default` first if the key is
absent. `default` is evaluated either way; use [`or_insert_with!`](@ref) when
it is costly to build.

# Returns
The value now stored first under the key.

# Examples
```jldoctest
julia> h = HeaderMap("content-type" => "text/html");

julia> or_insert!(entry(h, "content-type"), "text/plain")
hv"text/html"

julia> or_insert!(entry(h, "cache-control"), "no-store")
hv"no-store"

julia> length(h)
2
```
"""
function or_insert! end
or_insert!(e::VacantEntry, default) = insert!(e, default)
or_insert!(e::OccupiedEntry, default) = e[]
"""
    or_insert_with!(f, e::Union{OccupiedEntry,VacantEntry})

The first value of the entry's key, inserting `f()` first if the key is absent.
`f` is called only then.

# Examples
```jldoctest
julia> h = HeaderMap();

julia> or_insert_with!(entry(h, "x-request-id")) do
           "generated"
       end
hv"generated"

julia> or_insert_with!(() -> error("not called"), entry(h, "x-request-id"))
hv"generated"
```
"""
function or_insert_with! end
or_insert_with!(f, e::VacantEntry) = insert!(e, f())
or_insert_with!(f, e::OccupiedEntry) = e[]

Base.getindex(e::OccupiedEntry) = e.map.values[e.index]
Base.setindex!(e::OccupiedEntry{T}, v) where {T} = (e.map.values[e.index] = convert(T, v); e)
Base.values(e::OccupiedEntry) = view(e.map.values, e.index:_h_run_end(e.map, e.index))
Base.iterate(e::OccupiedEntry, st...) = iterate(values(e), st...)
Base.length(e::OccupiedEntry) = _h_run_end(e.map, e.index) - e.index + 1
Base.eltype(::Type{OccupiedEntry{T}}) where {T} = T

"""
    insert!(e::OccupiedEntry, value)

Make `value` the only value of the entry's key and return the old first value.
[`insert_mult!`](@ref) returns all the old values.
"""
Base.insert!(e::OccupiedEntry{T}, v) where {T} = _h_replace_run!(e.map, e.index, convert(T, v))

"""
    insert_mult!(e::OccupiedEntry, value) -> Vector

Make `value` the only value of the entry's key and return every value it had.

# Examples
```jldoctest
julia> h = HeaderMap("accept" => "text/html", "accept" => "text/plain");

julia> old = insert_mult!(entry(h, "accept"), "*/*");

julia> length(old), h
(2, HeaderMap(hn"accept" => hv"*/*"))
```
"""
function insert_mult!(e::OccupiedEntry{T}, v) where {T}
    old = collect(values(e))
    _h_replace_run!(e.map, e.index, convert(T, v))
    return old
end

"""
    append!(e::OccupiedEntry, value) -> Nothing

Add `value` after the values the entry's key already has.
See [`OccupiedEntry`](@ref).
"""
function Base.append!(e::OccupiedEntry{T}, v) where {T}
    _h_append_at!(e.map, e.key, convert(T, v), _h_run_end(e.map, e.index))
    return nothing
end

remove!(e::OccupiedEntry) = remove_entry!(e)[2]
"""
    remove_entry!(e::OccupiedEntry) -> Tuple{HeaderName,T}

Remove the entry's key from the map and return `(name, first value)`. The entry
must not be used afterwards.

# Examples
```jldoctest
julia> h = HeaderMap("accept" => "text/html", "accept" => "text/plain");

julia> remove_entry!(entry(h, "accept"))
(hn"accept", hv"text/html")

julia> isempty(h)
true
```
"""
function remove_entry!(e::OccupiedEntry)
    old = e[]
    _h_remove_run!(e.map, e.index, _h_run_end(e.map, e.index))
    return (e.key, old)
end
"""
    remove_entry_mult!(e::OccupiedEntry) -> Tuple{HeaderName,Vector{T}}

Remove the entry's key from the map and return `(name, all its values)`. The
entry must not be used afterwards.

# Examples
```jldoctest
julia> h = HeaderMap("accept" => "text/html", "accept" => "text/plain");

julia> name, values = remove_entry_mult!(entry(h, "accept"));

julia> name, length(values)
(hn"accept", 2)
```
"""
function remove_entry_mult!(e::OccupiedEntry)
    old = collect(values(e))
    _h_remove_run!(e.map, e.index, _h_run_end(e.map, e.index))
    return (e.key, old)
end
