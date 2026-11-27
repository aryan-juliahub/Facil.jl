"""
    percent_decode(s; plus = false) -> String

Decode `%XX` escapes in `s`. With `plus = true`, `+` also becomes a space, as
in a query string or form body.

Decoding is lenient, like the WHATWG URL standard: a `%` that is not followed
by two hex digits is kept as it is, and bytes that are not valid UTF-8 after
decoding become `'\\ufffd'`. It never throws on client input.

# Examples
```jldoctest
julia> percent_decode("caf%C3%A9%20au%20lait")
"café au lait"

julia> percent_decode("a+b%2Bc"; plus = true)
"a b+c"

julia> percent_decode("100%")
"100%"
```
"""
percent_decode(s::AbstractString; plus::Bool = false) = _decode(s, plus, false)::String

"""
    percent_encode(s) -> String

Escape every byte of `s` except the RFC 3986 unreserved characters
(`A-Z a-z 0-9 - . _ ~`) as `%XX`. The result is safe in a path segment, a query
name or value, a form body and a cookie value; [`percent_decode`](@ref)
reverses it.

# Examples
```jldoctest
julia> percent_encode("café & co/2")
"caf%C3%A9%20%26%20co%2F2"
```
"""
function percent_encode(s::AbstractString)
    str = String(s)
    cu = codeunits(str)
    n = 0
    @inbounds for b in cu
        n += _unreserved(b) ? 1 : 3
    end
    n == length(cu) && return str
    out = Base.StringVector(n)
    i = 1
    @inbounds for b in cu
        if _unreserved(b)
            out[i] = b
            i += 1
        else
            out[i] = UInt8('%')
            out[i+1] = _HEX[(b >> 4) + 1]
            out[i+2] = _HEX[(b & 0x0f) + 1]
            i += 3
        end
    end
    String(out)
end

const _HEX = codeunits("0123456789ABCDEF")

@inline _unreserved(b::UInt8) =
    (UInt8('a') <= b <= UInt8('z')) | (UInt8('A') <= b <= UInt8('Z')) | (UInt8('0') <= b <= UInt8('9')) |
    (b == UInt8('-')) | (b == UInt8('.')) | (b == UInt8('_')) | (b == UInt8('~'))

@inline function _hexval(b::UInt8)
    UInt8('0') <= b <= UInt8('9') && return b - UInt8('0')
    UInt8('a') <= b <= UInt8('f') && return b - UInt8('a') + 0x0a
    UInt8('A') <= b <= UInt8('F') && return b - UInt8('A') + 0x0a
    return 0xff
end

# Strict mode returns `nothing` for a bad escape, an escaped `/` or NUL, or
# invalid UTF-8; lenient mode keeps bad escapes and replaces invalid UTF-8.
function _decode(s::AbstractString, plus::Bool, strict::Bool)
    str = s isa Union{String,SubString{String}} ? s : String(s)
    cu = codeunits(str)
    n = length(cu)
    first = 0
    @inbounds for i in 1:n
        b = cu[i]
        if b == UInt8('%') || (plus && b == UInt8('+'))
            first = i
            break
        end
    end
    if first == 0
        out = String(str)
        return strict && !isvalid(out) ? nothing : out
    end
    buf = Base.StringVector(n)
    copyto!(buf, 1, cu, 1, first - 1)
    j = first - 1
    i = first
    @inbounds while i <= n
        b = cu[i]
        if b == UInt8('%')
            hi = i + 2 <= n ? _hexval(cu[i+1]) : 0xff
            lo = i + 2 <= n ? _hexval(cu[i+2]) : 0xff
            if (hi | lo) == 0xff
                strict && return nothing
                buf[j += 1] = b
                i += 1
            else
                c = (hi << 4) | lo
                strict && (c == UInt8('/') || c == 0x00) && return nothing
                buf[j += 1] = c
                i += 3
            end
        elseif plus && b == UInt8('+')
            buf[j += 1] = UInt8(' ')
            i += 1
        else
            buf[j += 1] = b
            i += 1
        end
    end
    out = String(resize!(buf, j))
    isvalid(out) && return out
    strict && return nothing
    map(c -> isvalid(c) ? c : '�', out)
end

# Calls `f(name, value)` with the raw (still encoded) parts of each `&`-separated
# pair, skipping empty pieces; stops early when `f` returns `true`.
function _eachpair(f, s::AbstractString, skipq::Bool = true)
    str = s isa Union{String,SubString{String}} ? s : String(s)
    cu = codeunits(str)
    n = length(cu)
    start = (skipq && n > 0 && @inbounds cu[1] == UInt8('?')) ? 2 : 1
    while start <= n
        stop = something(findnext(==(UInt8('&')), cu, start), n + 1)
        if stop > start
            eq = findnext(==(UInt8('=')), cu, start)
            if eq === nothing || eq > stop
                f(SubString(str, start, prevind(str, stop)), SubString(str, stop, stop - 1)) === true && return
            else
                f(SubString(str, start, prevind(str, eq)), SubString(str, eq + 1, prevind(str, stop))) === true && return
            end
        end
        start = stop + 1
    end
    nothing
end

"""
    parse_query(s) -> Vector{Pair{String,String}}

Split a query string or `application/x-www-form-urlencoded` text into
`name => value` pairs, in order, as `URLSearchParams` does: pairs are separated
by `&`, the first `=` separates name and value (a piece without `=` has the
value `""`), `+` is a space, and both sides are [`percent_decode`](@ref)d.
Empty pieces are skipped, a leading `?` is ignored, and a repeated name gives
one pair per occurrence.

# Examples
```jldoctest
julia> parse_query("tag=a&tag=b&q=caf%C3%A9+au+lait&flag")
4-element Vector{Pair{String, String}}:
  "tag" => "a"
  "tag" => "b"
    "q" => "café au lait"
 "flag" => ""
```
"""
parse_query(s::AbstractString) = _parse_pairs(s, true)

function _parse_pairs(s::AbstractString, skipq::Bool)
    out = Pair{String,String}[]
    _eachpair(s, skipq) do k, v
        push!(out, _decode(k, true, false) => _decode(v, true, false))
        false
    end
    out
end

"""
    parse_form(body) -> Vector{Pair{String,String}}
    parse_form(req::Request) -> Vector{Pair{String,String}}

Parse an `application/x-www-form-urlencoded` body (a string or bytes) with the
same rules as [`parse_query`](@ref). Given a request, parses `body(req)`; check
its `content-type` first if your handler also accepts other bodies.

# Examples
```jldoctest
julia> req = Request(; method = "POST", uri = "/login", body = "user=ada&note=hi+there%21");

julia> parse_form(req)
2-element Vector{Pair{String, String}}:
 "user" => "ada"
 "note" => "hi there!"
```
"""
parse_form(body::AbstractString) = _parse_pairs(body, false)
parse_form(body::AbstractVector{UInt8}) = _parse_pairs(String(copy(body)), false)
parse_form(req::Request) = parse_form(HttpTypes.body(req))

"""
    query_params(req::Request) -> Vector{Pair{String,String}}

The query of the request target as decoded `name => value` pairs, in order,
repeated names included: [`parse_query`](@ref) of `query(uri(req))`. Empty when
the target has no query.

# Examples
```jldoctest
julia> req = Request(; uri = "/search?q=julia+web&tag=a&tag=b");

julia> query_params(req)
3-element Vector{Pair{String, String}}:
   "q" => "julia web"
 "tag" => "a"
 "tag" => "b"

julia> [v for (k, v) in query_params(req) if k == "tag"]
2-element Vector{String}:
 "a"
 "b"
```
"""
query_params(req::Request) = parse_query(something(query(uri(req)), ""))

"""
    query_param(req::Request, name; default = nothing)

The decoded value of the first query parameter called `name`, or `default` when
there is none. Names compare exactly, after decoding. Only the names are decoded
until the match is found.

# Examples
```jldoctest
julia> req = Request(; uri = "/search?q=julia+web&page=2&q=other");

julia> query_param(req, "q"), query_param(req, "missing"), query_param(req, "n"; default = "1")
("julia web", nothing, "1")
```
"""
function query_param(req::Request, name::AbstractString; default = nothing)
    q = query(uri(req))
    q === nothing && return default
    found = Ref{Union{Nothing,String}}(nothing)
    _eachpair(q) do k, v
        _decode(k, true, false) == name || return false
        found[] = _decode(v, true, false)
        true
    end
    something(found[], Some(default))
end

"""
    decoded_path(req::Request) -> Union{String,Nothing}

The path of the request target with `%XX` escapes decoded (`/caf%C3%A9` gives
`"/café"`). `+` stays `+`: it is a space only in queries and forms.

Returns `nothing`, so you can answer 400, when decoding would be ambiguous or
unsafe: a malformed escape (`%zz`, `%4`), an escaped `/` (`%2F`), an escaped NUL
(`%00`), or bytes that are not valid UTF-8. The result is not normalised:
`%2E%2E` decodes to `..`. To accept `%2F` inside a segment, split
`path(uri(req))` on `/` first and [`percent_decode`](@ref) each segment.

# Examples
```jldoctest
julia> decoded_path(Request(; uri = "/caf%C3%A9/a+b"))
"/café/a+b"

julia> decoded_path(Request(; uri = "/files/a%2Fb")) === nothing
true
```
"""
decoded_path(req::Request) = _decode(path(uri(req)), false, true)
