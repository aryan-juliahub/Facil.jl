using Facil

serve("127.0.0.1", 8080) do req
    p = decoded_path(req)
    p === nothing && return Response(StatusCodes.BAD_REQUEST, "bad path\n")
    name = query_param(req, "name"; default = "world")
    tags = [v for (k, v) in query_params(req) if k == "tag"]
    Response(StatusCodes.OK, "path: $p\nhello $name\ntags: $(join(tags, ", "))\n")
end
