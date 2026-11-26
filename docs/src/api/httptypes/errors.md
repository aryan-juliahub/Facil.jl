```@meta
CurrentModule = HttpTypes
```

# Errors

This page lists every error HttpTypes throws and what causes each. Use it to
decide what to catch around code that builds HTTP values from untrusted text.

## Handling errors

All of them are subtypes of [`HttpError`](@ref), so one `catch` covers every
validation failure:

```@repl errors
using HttpTypes
function parse_target(text)
    try
        Uri(text)
    catch e
        e isa HttpError || rethrow()
        "rejected: " * sprint(showerror, e)
    end
end
parse_target("/users/42")
parse_target("/users/4 2")
```

When a failure is expected, `tryparse` avoids the exception altogether:

```@repl errors
tryparse(StatusCode, "20x") === nothing
tryparse(HeaderValue, "line\nbreak") === nothing
```

| Error | Message | Thrown by |
|:--|:--|:--|
| [`InvalidMethod`](@ref) | `invalid HTTP method` | [`HttpMethod`](@ref), `Request(; method)` |
| [`InvalidStatusCode`](@ref) | `invalid status code` | [`StatusCode`](@ref), `Response(; status)` |
| [`InvalidHeaderName`](@ref) | `invalid HTTP header name` | [`HeaderName`](@ref), [`HeaderMap`](@ref) writes, [`entry`](@ref) |
| [`InvalidHeaderValue`](@ref) | `failed to parse header value` | [`HeaderValue`](@ref), [`HeaderMap`](@ref) writes |
| [`ToStrError`](@ref) | `failed to convert header to a str` | [`to_str`](@ref) |
| [`MaxSizeReached`](@ref) | `max size reached` | [`HeaderMap`](@ref) growth, [`reserve!`](@ref) |
| [`InvalidUri`](@ref) | depends on `kind` | [`Uri`](@ref), [`Scheme`](@ref), [`Authority`](@ref), [`PathAndQuery`](@ref), [`Port`](@ref) |
| [`InvalidUriParts`](@ref) | depends on the cause | `Uri(parts)`, `Uri(; scheme, authority, path_and_query)` |

Lookups that miss are not `HttpError`s: `headers[name]` and `extensions[T]`
throw `KeyError`, like a `Dict`.

## Reference

```@docs
HttpError
InvalidMethod
InvalidStatusCode
InvalidHeaderName
InvalidHeaderValue
ToStrError
MaxSizeReached
InvalidUri
InvalidUriParts
HttpTypes.Error
HttpTypes.get_ref
```
