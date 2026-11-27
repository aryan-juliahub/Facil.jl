"""
    cookies(req::Request; unescape = false) -> Dict{String,String}

The cookies the client sent, from every `cookie` header, as `name => value`.

Parsing is lenient, as RFC 6265 §5.4 asks of servers: each header is split on
`;`, spaces and tabs around each piece are trimmed, the first `=` separates
name and value, and a value wrapped in double quotes loses them. Pieces with no
`=` or an empty name are skipped. When a name repeats, the first value wins
(browsers send the most specific cookie first).

Values are returned as sent. With `unescape = true` each value is
[`percent_decode`](@ref)d, which reverses `set_cookie!(...; escape = true)`.

# Examples
```jldoctest
julia> req = Request(; headers = ["cookie" => "sid=abc123; theme=\\"dark\\"", "cookie" => "sid=old; lang=en"]);

julia> c = cookies(req);

julia> c["sid"], c["theme"], c["lang"]
("abc123", "dark", "en")
```
"""
function cookies(req::Request; unescape::Bool = false)
    d = Dict{String,String}()
    for v in get_all(headers(req), header.COOKIE)
        _parse_cookie_header!(d, as_str(v), unescape)
    end
    d
end

function _parse_cookie_header!(d::Dict{String,String}, s::String, unescape::Bool)
    cu = codeunits(s)
    n = length(cu)
    start = 1
    while start <= n
        stop = something(findnext(==(UInt8(';')), cu, start), n + 1)
        a, b = _trim(cu, start, stop - 1)
        eq = a <= b ? findnext(==(UInt8('=')), cu, a) : nothing
        if eq !== nothing && eq <= b
            na, nb = _trim(cu, a, eq - 1)
            va, vb = _trim(cu, eq + 1, b)
            if vb > va && cu[va] == UInt8('"') && cu[vb] == UInt8('"')
                va += 1
                vb -= 1
            end
            if na <= nb
                name = String(cu[na:nb])
                if !haskey(d, name)
                    value = String(cu[va:vb])
                    d[name] = unescape ? percent_decode(value) : value
                end
            end
        end
        start = stop + 1
    end
    d
end

@inline _ows(b::UInt8) = b == UInt8(' ') || b == UInt8('\t')

function _trim(cu, a::Int, b::Int)
    while a <= b && _ows(@inbounds cu[a])
        a += 1
    end
    while b >= a && _ows(@inbounds cu[b])
        b -= 1
    end
    a, b
end

const _TCHAR_PUNCT = codeunits("!#\$%&'*+-.^_`|~")
_tchar(b::UInt8) = (UInt8('a') <= b <= UInt8('z')) | (UInt8('A') <= b <= UInt8('Z')) |
    (UInt8('0') <= b <= UInt8('9')) | (b in _TCHAR_PUNCT)
_cookie_octet(b::UInt8) = b == 0x21 || 0x23 <= b <= 0x2b || 0x2d <= b <= 0x3a || 0x3c <= b <= 0x5b || 0x5d <= b <= 0x7e
_av_octet(b::UInt8) = 0x20 <= b <= 0x7e && b != UInt8(';')

function _valid_cookie_value(v::String)
    cu = codeunits(v)
    if length(cu) >= 2 && cu[1] == UInt8('"') && cu[end] == UInt8('"')
        cu = view(cu, 2:length(cu)-1)
    end
    all(_cookie_octet, cu)
end

const _IMF_FIXDATE = Dates.DateFormat("e, dd u yyyy HH:MM:SS")

"""
    set_cookie!(res::Response, name, value; path = nothing, domain = nothing,
                max_age = nothing, expires = nothing, secure = false,
                http_only = false, same_site = nothing, partitioned = false,
                escape = false) -> res

Append one `set-cookie` header to `res`; call it once per cookie.

- `name` must be an HTTP token (letters, digits and ``!#\$%&'*+-.^_`|~``).
- `value` must consist of cookie octets: visible ASCII except space, `"`, `,`,
  `;` and `\\`. Pass `escape = true` to [`percent_encode`](@ref) it first (read
  it back with `cookies(req; unescape = true)`), or encode it yourself.
- `max_age` is in seconds (an `Integer` or a `Dates.Period`); `expires` is a
  `DateTime` in UTC, sent as an IMF-fixdate.
- `same_site` is `:strict`, `:lax` or `:none`. `:none` and `partitioned = true`
  require `secure = true`, as browsers do.
- A name starting with `__Secure-` requires `secure = true`; one starting with
  `__Host-` also requires `path = "/"` and no `domain`.

Throws an `ArgumentError` for anything a browser would reject or that would
break the header.

# Examples
```jldoctest
julia> res = Response(StatusCodes.OK, "ok");

julia> set_cookie!(res, "sid", "abc123"; path = "/", http_only = true, secure = true, same_site = :lax);

julia> set_cookie!(res, "theme", "dark"; max_age = 3600);

julia> String.(get_all(headers(res), "set-cookie"))
2-element Vector{String}:
 "sid=abc123; Path=/; Secure; HttpOnly; SameSite=Lax"
 "theme=dark; Max-Age=3600"
```
"""
function set_cookie!(res::Response, name::AbstractString, value::AbstractString;
                     path::Union{Nothing,AbstractString} = nothing,
                     domain::Union{Nothing,AbstractString} = nothing,
                     max_age::Union{Nothing,Integer,Dates.Period} = nothing,
                     expires::Union{Nothing,Dates.DateTime} = nothing,
                     secure::Bool = false, http_only::Bool = false,
                     same_site::Union{Nothing,Symbol} = nothing,
                     partitioned::Bool = false, escape::Bool = false)
    name = String(name)
    value = escape ? percent_encode(value) : String(value)
    !isempty(name) && all(_tchar, codeunits(name)) ||
        throw(ArgumentError("invalid cookie name $(repr(name)): use letters, digits and !#\$%&'*+-.^_`|~"))
    _valid_cookie_value(value) ||
        throw(ArgumentError("invalid cookie value $(repr(value)) for $name: escape it, for example with `escape = true`"))
    for (k, v) in (("path", path), ("domain", domain))
        v === nothing || all(_av_octet, codeunits(v)) ||
            throw(ArgumentError("invalid cookie $k $(repr(v)): no control characters or ';'"))
    end
    same_site in (nothing, :strict, :lax, :none) ||
        throw(ArgumentError("same_site must be :strict, :lax, :none or nothing, got $(repr(same_site))"))
    same_site === :none && !secure && throw(ArgumentError("same_site = :none requires secure = true"))
    partitioned && !secure && throw(ArgumentError("partitioned = true requires secure = true"))
    if startswith(name, "__Secure-") || startswith(name, "__Host-")
        secure || throw(ArgumentError("a cookie named $name requires secure = true"))
    end
    if startswith(name, "__Host-")
        (path == "/" && domain === nothing) ||
            throw(ArgumentError("a cookie named $name requires path = \"/\" and no domain"))
    end
    io = IOBuffer()
    print(io, name, '=', value)
    path === nothing || print(io, "; Path=", path)
    domain === nothing || print(io, "; Domain=", domain)
    max_age === nothing || print(io, "; Max-Age=", max_age isa Integer ? max_age :
                                 Dates.value(Dates.Second(max_age)))
    expires === nothing || print(io, "; Expires=", Dates.format(expires, _IMF_FIXDATE), " GMT")
    secure && print(io, "; Secure")
    http_only && print(io, "; HttpOnly")
    same_site === nothing || print(io, "; SameSite=", same_site === :strict ? "Strict" : same_site === :lax ? "Lax" : "None")
    partitioned && print(io, "; Partitioned")
    append!(headers(res), header.SET_COOKIE, HeaderValue(String(take!(io))))
    res
end

"""
    delete_cookie!(res::Response, name; path = nothing, domain = nothing, kw...) -> res

Tell the client to drop the cookie `name`: a `set-cookie` with an empty value,
`Max-Age=0` and an `Expires` in 1970. `path` and `domain` must match the ones
the cookie was set with, or the browser keeps it. Other keywords go to
[`set_cookie!`](@ref) (a `__Host-` cookie needs `secure = true, path = "/"`).

# Examples
```jldoctest
julia> res = delete_cookie!(Response(StatusCodes.OK, "bye"), "sid"; path = "/");

julia> String(headers(res)["set-cookie"])
"sid=; Path=/; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT"
```
"""
delete_cookie!(res::Response, name::AbstractString; kw...) =
    set_cookie!(res, name, ""; kw..., max_age = 0, expires = Dates.DateTime(1970))
