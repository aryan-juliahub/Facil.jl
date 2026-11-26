"""
    HttpError <: Exception

Supertype of every error this package throws.

| Error | Thrown when |
|:--|:--|
| [`InvalidMethod`](@ref) | a method is not a valid token |
| [`InvalidStatusCode`](@ref) | a status code is outside `100:999` |
| [`InvalidHeaderName`](@ref) | a header name is not a valid token |
| [`InvalidHeaderValue`](@ref) | a header value holds a forbidden byte |
| [`ToStrError`](@ref) | [`to_str`](@ref) meets a byte outside visible ASCII |
| [`MaxSizeReached`](@ref) | a [`HeaderMap`](@ref) would exceed its size limit |
| [`InvalidUri`](@ref) | a URI or one of its components does not parse |
| [`InvalidUriParts`](@ref) | [`UriParts`](@ref) do not combine into a URI |

[`HttpTypes.Error`](@ref) wraps any of them in one concrete type.

Catch `HttpError` to handle every validation failure in one place. Lookups that
miss throw the usual Base errors instead (`KeyError`), and passing a value of the
wrong type is a `MethodError` or `ArgumentError`.

# Examples
```jldoctest
julia> try
           Request(; method = "G T")
       catch e
           e isa HttpError, sprint(showerror, e)
       end
(true, "invalid HTTP method")
```
"""
abstract type HttpError <: Exception end
export HttpError

"""
    HttpTypes.Error(err::HttpError)

One concrete error type that wraps any [`HttpError`](@ref) (the crate's general
`http::Error`). Not exported.

Nothing in this package throws an `Error`; it exists for code that wants to store
or return a single error type.

# Arguments
- `err::HttpError`: the error to wrap. An `Error` is returned unchanged, so errors
  never nest.

# Returns
An `Error`. [`HttpTypes.get_ref`](@ref) gives back the wrapped error. `showerror`
prints the wrapped error's message. `convert(HttpTypes.Error, err)` does the same
as the constructor.

# Examples
```jldoctest
julia> err = HttpTypes.Error(InvalidMethod())
HttpTypes.Error(InvalidMethod())

julia> HttpTypes.get_ref(err) isa InvalidMethod
true

julia> HttpTypes.Error(err) === err
true

julia> sprint(showerror, err)
"invalid HTTP method"
```
"""
struct Error <: HttpError
    inner::HttpError
    Error(e::HttpError) = e isa Error ? e : new(e)
end

"""
    HttpTypes.get_ref(e::HttpTypes.Error) -> HttpError

The specific error wrapped by an [`HttpTypes.Error`](@ref). Not exported.

The crate's `e.is::<T>()` is `HttpTypes.get_ref(e) isa T`.

# Examples
```jldoctest
julia> HttpTypes.get_ref(HttpTypes.Error(InvalidStatusCode()))
InvalidStatusCode()
```
"""
get_ref(e::Error) = getfield(e, :inner)

Base.convert(::Type{Error}, e::HttpError) = Error(e)
Base.showerror(io::IO, e::Error) = showerror(io, get_ref(e))
function Base.show(io::IO, e::Error)
    print(io, "HttpTypes.Error(")
    show(io, get_ref(e))
    print(io, ")")
end
