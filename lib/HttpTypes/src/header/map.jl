export HeaderMap, MaxSizeReached, get_all, keys_len, remove!, drain!, extend!, reserve!,
    entry, OccupiedEntry, VacantEntry, key, or_insert!, or_insert_with!, insert_entry!,
    insert_mult!, remove_entry!, remove_entry_mult!

"""
    MaxSizeReached

Thrown when a `HeaderMap` would hold more distinct names than it allows (24,576).
"""
struct MaxSizeReached <: HttpError end
Base.showerror(io::IO, ::MaxSizeReached) = print(io, "max size reached")

const _H_MAX_SIZE = 1 << 15
const _H_MAX_KEYS = _H_MAX_SIZE - _H_MAX_SIZE ÷ 4

"""
    HeaderMap{T}()
    HeaderMap{T}(capacity::Integer)
    HeaderMap(pairs...)  /  HeaderMap(itr)

A multimap from `HeaderName` to `T` (default `HeaderValue`). Iteration yields
`name => value` in insertion order of the names, with all values of one name
together; removing a name moves the last name into its place.
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

"`sizehint!(h, n)` makes room for `n` values; throws `MaxSizeReached` past the limit."
function Base.sizehint!(h::HeaderMap, n::Integer)
    _h_check_capacity(n)
    sizehint!(h.names, n)
    sizehint!(h.values, n)
    return h
end

"""
    reserve!(h, additional)

Make room for `additional` more names; throws `MaxSizeReached` past the limit.
"""
function reserve!(h::HeaderMap, additional::Integer)
    (additional < 0 || additional > _H_MAX_SIZE) && throw(MaxSizeReached())
    _h_check_capacity(h.nkeys + additional)
    sizehint!(h.names, length(h.names) + additional)
    sizehint!(h.values, length(h.values) + additional)
    return h
end

Base.copy(h::HeaderMap) = _h_map_unchecked(copy(h.names), copy(h.values), h.nkeys)

"Number of values, counting each value of a repeated name."
Base.length(h::HeaderMap) = length(h.values)
"`keys_len(h)` is the number of distinct names."
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

Base.haskey(h::HeaderMap, k) = _h_find(h, k) != 0

@inline function Base.get(h::HeaderMap, k, default)
    i = _h_find(h, k)
    return i == 0 ? default : @inbounds h.values[i]
end

function Base.get(f::Base.Callable, h::HeaderMap, k)
    i = _h_find(h, k)
    return i == 0 ? f() : @inbounds h.values[i]
end

"`h[k]` is the first value of `k`; throws `KeyError` if absent."
@inline function Base.getindex(h::HeaderMap, k)
    i = _h_find(h, k)
    i == 0 && throw(KeyError(k))
    return @inbounds h.values[i]
end

"""
    get_all(h, key)

A view of every value stored under `key`, in the order they were added. It
reads (and writes) the map's storage, so it is stale once the map changes.
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
    insert!(h, key, value)

Set `key` to the single `value`, keeping its position. Returns the first value
it replaced, or `nothing`. `h[key] = value` is the same without the return.
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

Base.setindex!(h::HeaderMap, v, k) = (insert!(h, k, v); h)

"""
    append!(h, key, value)

Add `value` under `key`, keeping existing ones. Returns `true` if the key was already present.
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
    remove!(ext::Extensions, T)

Remove every value of `key` from a `HeaderMap` and return the first one, or `nothing`
if the key was absent. For an `OccupiedEntry`, remove its key and return its first value.
For `Extensions`, remove and return the value of type `T`, or `nothing`.
"""
function remove! end

function remove!(h::HeaderMap, k)
    i = _h_find(h, k)
    i == 0 && return nothing
    old = @inbounds h.values[i]
    _h_remove_run!(h, i, _h_run_end(h, i))
    return old
end

Base.delete!(h::HeaderMap, k) = (remove!(h, k); h)
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
    drain!(h)

Empty the map and return its contents as `name => value` pairs. Values after the
first of a name carry `nothing` as their name.
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
    extend!(h, itr)

Add `key => value` pairs, appending to names already present. When the keys are
typed `Union{Nothing,HeaderName}` (the output of `drain!`), a named pair
replaces the values of that name and a `nothing` key appends to the previous name.
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

"`values(h)` is a view of every value in iteration order; assigning into it updates the map."
Base.values(h::HeaderMap) = view(h.values, 1:length(h.values))

struct HeaderKeys{T}
    map::HeaderMap{T}
end
"`keys(h)` iterates each distinct name once."
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
    OccupiedEntry

A key that is present, from `entry`. `e[]` is its first value and `e[] = v`
replaces that value only; `values(e)` views them all. Stale once the map is
changed through anything else.
"""
struct OccupiedEntry{T}
    map::HeaderMap{T}
    key::HeaderName
    index::Int
end

"A key that is absent, from `entry`. Fill it with `insert!` or `insert_entry!`."
struct VacantEntry{T}
    map::HeaderMap{T}
    key::HeaderName
end

"""
    entry(h, key)

An `OccupiedEntry` or a `VacantEntry` for in-place work on one key.
"""
function entry(h::HeaderMap{T}, k) where {T}
    name = _h_to_name(k)
    i = _h_find(h, name)
    return i == 0 ? VacantEntry{T}(h, name) : OccupiedEntry{T}(h, name, i)
end

"`key(e)` is the entry's `HeaderName`."
key(e::Union{OccupiedEntry,VacantEntry}) = e.key

"`insert_entry!(e::VacantEntry, v)` adds `v` and returns the new `OccupiedEntry`."
function insert_entry!(e::VacantEntry{T}, v) where {T}
    _h_push_new!(e.map, e.key, convert(T, v))
    return OccupiedEntry{T}(e.map, e.key, length(e.map.names))
end
"`insert!(e::VacantEntry, v)` adds `v` and returns it."
Base.insert!(e::VacantEntry, v) = insert_entry!(e, v)[]

"`or_insert!(e, default)` is the first value of an `OccupiedEntry`, or inserts `default` into a `VacantEntry`."
function or_insert! end
or_insert!(e::VacantEntry, default) = insert!(e, default)
or_insert!(e::OccupiedEntry, default) = e[]
"`or_insert_with!(f, e)` is the first value of an `OccupiedEntry`, or inserts `f()` into a `VacantEntry`."
function or_insert_with! end
or_insert_with!(f, e::VacantEntry) = insert!(e, f())
or_insert_with!(f, e::OccupiedEntry) = e[]

Base.getindex(e::OccupiedEntry) = e.map.values[e.index]
Base.setindex!(e::OccupiedEntry{T}, v) where {T} = (e.map.values[e.index] = convert(T, v); e)
Base.values(e::OccupiedEntry) = view(e.map.values, e.index:_h_run_end(e.map, e.index))
Base.iterate(e::OccupiedEntry, st...) = iterate(values(e), st...)
Base.length(e::OccupiedEntry) = _h_run_end(e.map, e.index) - e.index + 1
Base.eltype(::Type{OccupiedEntry{T}}) where {T} = T

"`insert!(e::OccupiedEntry, v)` makes `v` the only value; returns the old first value."
Base.insert!(e::OccupiedEntry{T}, v) where {T} = _h_replace_run!(e.map, e.index, convert(T, v))

"`insert_mult!(e, v)` makes `v` the only value; returns all the old values."
function insert_mult!(e::OccupiedEntry{T}, v) where {T}
    old = collect(values(e))
    _h_replace_run!(e.map, e.index, convert(T, v))
    return old
end

"`append!(e::OccupiedEntry, v)` adds `v` after the entry's values."
function Base.append!(e::OccupiedEntry{T}, v) where {T}
    _h_append_at!(e.map, e.key, convert(T, v), _h_run_end(e.map, e.index))
    return nothing
end

remove!(e::OccupiedEntry) = remove_entry!(e)[2]
"`remove_entry!(e)` removes the key; returns `(name, first value)`."
function remove_entry!(e::OccupiedEntry)
    old = e[]
    _h_remove_run!(e.map, e.index, _h_run_end(e.map, e.index))
    return (e.key, old)
end
"`remove_entry_mult!(e)` removes the key; returns `(name, all values)`."
function remove_entry_mult!(e::OccupiedEntry)
    old = collect(values(e))
    _h_remove_run!(e.map, e.index, _h_run_end(e.map, e.index))
    return (e.key, old)
end
