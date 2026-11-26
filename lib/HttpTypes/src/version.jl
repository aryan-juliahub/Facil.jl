export Version, Versions

"""
    Version
    Version()

The HTTP protocol version of a request or response.

There are exactly five values, the constants in `Versions`: `Versions.HTTP_09`,
`Versions.HTTP_10`, `Versions.HTTP_11`, `Versions.HTTP_2` and `Versions.HTTP_3`.
A `Version` cannot be parsed from text or built from a number.

# Returns
`Version()` is `Versions.HTTP_11`, the default of [`Request`](@ref) and
[`Response`](@ref).

# Notes
- Versions are ordered oldest first, so `v >= Versions.HTTP_11` works.
- [`as_str`](@ref), `string(v)` and `print` give `"HTTP/1.1"`; HTTP/2 and HTTP/3
  print as `"HTTP/2.0"` and `"HTTP/3.0"`. `show` prints `Versions.HTTP_11`.

# Examples
```jldoctest
julia> Version()
Versions.HTTP_11

julia> Versions.HTTP_10 < Versions.HTTP_11
true

julia> string(Versions.HTTP_2)
"HTTP/2.0"
```
"""
struct Version
    v::UInt8
    global _v_unchecked(v::UInt8) = new(v)
end

const _V_TABLE = ((:HTTP_09, "HTTP/0.9"), (:HTTP_10, "HTTP/1.0"), (:HTTP_11, "HTTP/1.1"),
    (:HTTP_2, "HTTP/2.0"), (:HTTP_3, "HTTP/3.0"))

"""
    Versions

The protocol versions as [`Version`](@ref HttpTypes.Version) constants: `Versions.HTTP_09`,
`Versions.HTTP_10`, `Versions.HTTP_11`, `Versions.HTTP_2`, `Versions.HTTP_3`.

# Examples
```jldoctest
julia> Versions.HTTP_11
Versions.HTTP_11

julia> maximum([Versions.HTTP_2, Versions.HTTP_10, Versions.HTTP_3])
Versions.HTTP_3
```
"""
baremodule Versions end
for (i, (k, _)) in enumerate(_V_TABLE)
    Core.eval(Versions, :(const $k = $(_v_unchecked(UInt8(i)))))
end

Version() = Versions.HTTP_11
as_str(v::Version) = @inbounds _V_TABLE[getfield(v, :v)][2]
Base.isless(a::Version, b::Version) = isless(a.v, b.v)
Base.print(io::IO, v::Version) = print(io, as_str(v))
Base.show(io::IO, v::Version) = print(io, "Versions.", _V_TABLE[getfield(v, :v)][1])
