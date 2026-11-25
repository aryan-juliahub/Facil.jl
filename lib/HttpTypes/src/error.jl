"""
    HttpError <: Exception

Supertype of every error this package throws: `InvalidMethod`, `InvalidStatusCode`,
`InvalidHeaderName`, `InvalidHeaderValue`, `ToStrError`, `MaxSizeReached`,
`InvalidUri`, `InvalidUriParts` and the wrapper [`HttpTypes.Error`](@ref).
"""
abstract type HttpError <: Exception end
export HttpError

"""
    HttpTypes.Error(err::HttpError)

The crate's general `http::Error`: one type that any error from this package converts
into, for code that wants a single error type. `get_ref(e)` is the wrapped error and
`showerror` prints its message. Wrapping an `Error` returns it unchanged. Not exported.

    try
        Request(; method = "G T")
    catch e
        err = HttpTypes.Error(e)
        HttpTypes.get_ref(err) isa InvalidMethod   # true
    end
"""
struct Error <: HttpError
    inner::HttpError
    Error(e::HttpError) = e isa Error ? e : new(e)
end

"""
    HttpTypes.get_ref(e::HttpTypes.Error)

The wrapped, more specific error. The crate's `e.is::<T>()` is `get_ref(e) isa T`.
"""
get_ref(e::Error) = getfield(e, :inner)

Base.convert(::Type{Error}, e::HttpError) = Error(e)
Base.showerror(io::IO, e::Error) = showerror(io, get_ref(e))
function Base.show(io::IO, e::Error)
    print(io, "HttpTypes.Error(")
    show(io, get_ref(e))
    print(io, ")")
end
