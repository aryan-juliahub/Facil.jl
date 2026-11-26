using Facil, URIs

serve("127.0.0.1", 8080) do req
    q = queryparams(something(query(uri(req)), ""))
    name = get(q, "name", "world")
    n = something(tryparse(Int, get(q, "n", "1")), 1)
    1 <= n <= 10 || return Response(StatusCodes.BAD_REQUEST, "n must be between 1 and 10\n")
    segments = unescapeuri.(split(path(uri(req)), '/'; keepempty = false))
    Response(StatusCodes.OK, join(fill("hello $name", n), "\n") * "\nsegments: $(join(segments, ", "))\n")
end
