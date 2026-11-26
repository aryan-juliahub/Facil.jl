using Facil

# Compares two strings in time that depends only on their lengths.
function same_secret(a::AbstractString, b::AbstractString)
    x, y = codeunits(a), codeunits(b)
    diff = length(x) ⊻ length(y)
    for i in 1:min(length(x), length(y))
        diff |= x[i] ⊻ y[i]
    end
    diff == 0
end

# Requires `Authorization: Bearer <token>` on every request.
function with_bearer_auth(handler, token::AbstractString)
    function (req)
        auth = get(headers(req), header.AUTHORIZATION, nothing)
        if auth === nothing || !same_secret(as_str(auth), "Bearer " * token)
            return Response(StatusCodes.UNAUTHORIZED, "unauthorized\n";
                            headers = [header.WWW_AUTHENTICATE => "Bearer"])
        end
        handler(req)
    end
end

# Answers CORS preflight requests and adds the allow-origin header for one origin.
function with_cors(handler, origin::AbstractString)
    function (req)
        if method(req) == Methods.OPTIONS && haskey(headers(req), header.ACCESS_CONTROL_REQUEST_METHOD)
            return Response(StatusCodes.NO_CONTENT;
                            headers = [header.ACCESS_CONTROL_ALLOW_ORIGIN => origin,
                                       header.ACCESS_CONTROL_ALLOW_METHODS => "GET, POST, OPTIONS",
                                       header.ACCESS_CONTROL_ALLOW_HEADERS => "authorization, content-type",
                                       header.ACCESS_CONTROL_MAX_AGE => "600",
                                       header.VARY => "origin"])
        end
        res = handler(req)
        res isa Response || (res = Response(StatusCodes.OK, String(res)))
        insert!(headers(res), header.ACCESS_CONTROL_ALLOW_ORIGIN, origin)
        append!(headers(res), header.VARY, "origin")
        res
    end
end

app(req) = Response(StatusCodes.OK, "the secret data\n")

const TOKEN = get(ENV, "API_TOKEN", "change-me")

# CORS outermost, so that preflight requests (which carry no credentials) pass.
serve(with_cors(with_bearer_auth(app, TOKEN), "https://app.example.com"), "127.0.0.1", 8080)
