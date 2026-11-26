using Facil, JSON

const JSON_TYPE = [header.CONTENT_TYPE => "application/json"]

json_response(status, data) = Response(status, JSON.json(data); headers = JSON_TYPE)

# The request body as parsed JSON, or `nothing` when it is not JSON.
function json_body(req)
    try
        JSON.parse(body(req))
    catch
        nothing
    end
end

function is_json(req)
    ct = get(headers(req), header.CONTENT_TYPE, nothing)
    ct !== nothing && startswith(lowercase(as_str(ct)), "application/json")
end

serve("127.0.0.1", 8080; body_in_memory = 1024 * 1024) do req
    m, p = method(req), path(uri(req))
    if m == Methods.GET && p == "/status"
        json_response(StatusCodes.OK, (status = "ok", julia = string(VERSION)))
    elseif m == Methods.POST && p == "/greet"
        is_json(req) || return json_response(StatusCodes.UNSUPPORTED_MEDIA_TYPE, (error = "send application/json",))
        data = json_body(req)
        data isa AbstractDict || return json_response(StatusCodes.BAD_REQUEST, (error = "the body must be a JSON object",))
        name = get(data, "name", nothing)
        name isa AbstractString || return json_response(StatusCodes.UNPROCESSABLE_ENTITY, (error = "name must be a string",))
        json_response(StatusCodes.CREATED, Dict("greeting" => "hello $name", "length" => length(name)))
    else
        json_response(StatusCodes.NOT_FOUND, (error = "not found",))
    end
end
