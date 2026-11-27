using Facil

const FORM = "application/x-www-form-urlencoded"

serve("127.0.0.1", 8080) do req
    method(req) == Methods.POST ||
        return Response(StatusCodes.METHOD_NOT_ALLOWED; headers = [header.ALLOW => "POST"])
    ct = get(headers(req), header.CONTENT_TYPE, nothing)
    ct !== nothing && startswith(as_str(ct), FORM) ||
        return Response(StatusCodes.UNSUPPORTED_MEDIA_TYPE, "send $FORM\n")
    form = parse_form(req)
    user = something(get(Dict(form), "user", nothing), "")
    isempty(user) && return Response(StatusCodes.BAD_REQUEST, "user is required\n")
    roles = [v for (k, v) in form if k == "role"]
    Response(StatusCodes.OK, "welcome $user\nroles: $(join(roles, ", "))\n")
end
