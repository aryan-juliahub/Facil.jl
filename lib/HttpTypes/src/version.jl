export Version, Versions

"""
    Version

The HTTP protocol version: `Versions.HTTP_09`, `HTTP_10`, `HTTP_11`, `HTTP_2`, `HTTP_3`.
Versions are ordered oldest first; the default is `Versions.HTTP_11`.
"""
struct Version
    v::UInt8
    global _v_unchecked(v::UInt8) = new(v)
end

const _V_TABLE = ((:HTTP_09, "HTTP/0.9"), (:HTTP_10, "HTTP/1.0"), (:HTTP_11, "HTTP/1.1"),
    (:HTTP_2, "HTTP/2.0"), (:HTTP_3, "HTTP/3.0"))

"The protocol versions: `Versions.HTTP_09`, `HTTP_10`, `HTTP_11`, `HTTP_2`, `HTTP_3`."
baremodule Versions end
for (i, (k, _)) in enumerate(_V_TABLE)
    Core.eval(Versions, :(const $k = $(_v_unchecked(UInt8(i)))))
end

Version() = Versions.HTTP_11
as_str(v::Version) = @inbounds _V_TABLE[getfield(v, :v)][2]
Base.isless(a::Version, b::Version) = isless(a.v, b.v)
Base.print(io::IO, v::Version) = print(io, as_str(v))
Base.show(io::IO, v::Version) = print(io, "Versions.", _V_TABLE[getfield(v, :v)][1])
