# [Cookies](@id cookies-guide)

This page shows how to read the cookies a client sends and how to set and
delete cookies in a response. Facil parses and writes the headers; sessions,
signing and encryption are up to you.

| You want | Call |
|---|---|
| the request's cookies | [`cookies`](@ref)`(req)`, a `Dict{String,String}` |
| set a cookie | [`set_cookie!`](@ref)`(res, name, value; attributes...)` |
| delete a cookie | [`delete_cookie!`](@ref)`(res, name; path, domain)` |

## A login cookie

```@eval
Main.example("cookies_session.jl")
```

```sh
$ curl -c jar.txt http://127.0.0.1:8080/login
logged in
$ curl -b jar.txt http://127.0.0.1:8080/me
session abc123, theme dark mode
$ curl -b jar.txt -c jar.txt http://127.0.0.1:8080/logout
logged out
$ curl -b jar.txt http://127.0.0.1:8080/me
no session
```

Behind HTTPS, add `secure = true` to every cookie that matters, so the browser
never sends it over plain HTTP.

## Reading cookies

`cookies(req)` reads every `cookie` header of the request:

```@example cookies
using Facil

req = Request(; headers = ["cookie" => "sid=abc123; theme=\"dark\"; lang=en",
                           "cookie" => "sid=other; note=a%20b"])
cookies(req)
```

The parsing is the lenient one RFC 6265 asks of servers:

- pieces are separated by `;`, and spaces and tabs around them are ignored;
- the first `=` separates name and value, so a value may contain `=`;
- a value wrapped in double quotes loses the quotes;
- a piece without `=`, or with an empty name, is skipped;
- when a name repeats, the first value wins. Browsers send the cookie with the
  longest matching path first, so the first is the most specific one.

Values come back exactly as sent. If you set them with `escape = true` (below),
read them with `unescape = true`:

```@example cookies
cookies(req; unescape = true)["note"]
```

A cookie value is whatever the client chose to send. Treat it as untrusted
input: a session id must be looked up, a signed value must be verified.

## Setting cookies

`set_cookie!(res, name, value; ...)` appends one `set-cookie` header and returns
`res`. Call it once per cookie; each becomes its own header line.

```@example cookies
res = Response(StatusCodes.OK, "ok")
set_cookie!(res, "sid", "abc123"; path = "/", http_only = true, secure = true, same_site = :lax)
set_cookie!(res, "seen", "1"; max_age = 86400)
String.(get_all(headers(res), "set-cookie"))
```

| Keyword | Attribute | Notes |
|---|---|---|
| `path` | `Path=` | the URL prefix the cookie is sent to; browsers default to the current directory, so set `path = "/"` for a site-wide cookie |
| `domain` | `Domain=` | omit it to limit the cookie to this exact host |
| `max_age` | `Max-Age=` | seconds, an `Integer` or a `Dates.Period` such as `Day(30)` |
| `expires` | `Expires=` | a `Dates.DateTime` in UTC; `max_age` wins when both are set |
| `secure = true` | `Secure` | sent over HTTPS only |
| `http_only = true` | `HttpOnly` | not visible to JavaScript |
| `same_site` | `SameSite=` | `:strict`, `:lax` or `:none` |
| `partitioned = true` | `Partitioned` | CHIPS: a separate cookie jar per top-level site |
| `escape = true` | | percent-encode the value first |

### What is checked

`set_cookie!` throws an `ArgumentError` instead of writing a header that is
broken or that browsers would silently drop:

- the name must be an HTTP token: letters, digits and ``!#$%&'*+-.^_`|~``;
- the value must use cookie characters only: visible ASCII except space, `"`,
  `,`, `;` and `\`. Encode anything else, with `escape = true` or your own
  encoding (base64url, for example);
- `path` and `domain` must not contain `;` or control characters;
- `same_site = :none` and `partitioned = true` require `secure = true`;
- a name starting with `__Secure-` requires `secure = true`, and one starting
  with `__Host-` also requires `path = "/"` and no `domain`.

```@example cookies
try
    set_cookie!(Response(StatusCodes.OK, ""), "note", "hello world")
catch e
    e
end
```

```@example cookies
res = set_cookie!(Response(StatusCodes.OK, ""), "note", "hello world; ok"; escape = true)
String(headers(res)["set-cookie"])
```

## Deleting cookies

A server cannot remove a cookie; it can only replace it with one that has
already expired. `delete_cookie!` does that, with `Max-Age=0` and an `Expires`
in 1970:

```@example cookies
res = delete_cookie!(Response(StatusCodes.OK, "bye"), "sid"; path = "/")
String(headers(res)["set-cookie"])
```

Pass the same `path` and `domain` the cookie was set with; otherwise the browser
treats it as a different cookie and keeps the old one.

## Coming from other libraries

| Elsewhere | Facil |
|---|---|
| Express `req.cookies` (cookie-parser) | `cookies(req; unescape = true)` |
| Express `res.cookie(name, value, {httpOnly: true, sameSite: 'lax'})` | `set_cookie!(res, name, value; http_only = true, same_site = :lax, escape = true)` |
| Express `res.clearCookie(name, {path})` | `delete_cookie!(res, name; path)` |
| HTTP.jl `HTTP.Cookies.cookies(req)` | `cookies(req)` |
| HTTP.jl `HTTP.Cookies.Cookie(...)`, `HTTP.Cookies.addcookie!(res, c)` | `set_cookie!(res, name, value; ...)` |
| Rust `cookie::Cookie::build(...)` | `set_cookie!` with keywords |

Express's `res.cookie` percent-encodes values by default; Facil does not, so
pass `escape = true` to get the same behaviour.
