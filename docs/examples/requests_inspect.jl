using Facil

function describe(req)
    h = headers(req)
    lines = [
        "method: $(method(req))",
        "path: $(path(uri(req)))",
        "query: $(something(query(uri(req)), "(none)"))",
        "version: $(version(req))",
        "host: $(h[header.HOST])",
        "user-agent: $(get(h, header.USER_AGENT, "(none)"))",
        "accept (all): $(join(get_all(h, "accept"), " | "))",
        "headers: $(length(h))",
        "body bytes: $(sizeof(body(req)))",
    ]
    Response(StatusCodes.OK, join(lines, "\n") * "\n")
end

serve(describe, "127.0.0.1", 8080)
