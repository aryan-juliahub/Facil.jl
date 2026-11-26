using Facil

serve("127.0.0.1", 8080) do req
    lines = [
        "method: $(method(req))",
        "path:   $(path(uri(req)))",
        "query:  $(something(query(uri(req)), "(none)"))",
        "agent:  $(get(headers(req), "user-agent", "(none)"))",
        "body:   $(sizeof(body(req))) bytes",
    ]
    Response(StatusCodes.OK, join(lines, "\n") * "\n"; headers = ["x-served-by" => "facil"])
end
