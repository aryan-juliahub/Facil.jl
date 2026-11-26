using Facil

#= snippet: router =#
struct Route
    method::HttpMethod
    segments::Vector{String}          # "users", ":id", ...
    handler::Function                 # (req, params) -> Response
end

struct Router
    routes::Vector{Route}
end
Router() = Router(Route[])

route!(r::Router, m::HttpMethod, pattern::String, handler) =
    (push!(r.routes, Route(m, split(pattern, '/'; keepempty = false), handler)); r)

function match_route(route::Route, segments)
    length(segments) == length(route.segments) || return nothing
    params = Dict{String,String}()
    for (pat, seg) in zip(route.segments, segments)
        if startswith(pat, ':')
            params[pat[2:end]] = seg
        elseif pat != seg
            return nothing
        end
    end
    params
end

function (r::Router)(req)
    segments = split(path(uri(req)), '/'; keepempty = false)
    allowed = String[]
    for route in r.routes
        params = match_route(route, segments)
        params === nothing && continue
        route.method == method(req) && return route.handler(req, params)
        push!(allowed, as_str(route.method))
    end
    isempty(allowed) && return Response(StatusCodes.NOT_FOUND, "not found\n")
    Response(StatusCodes.METHOD_NOT_ALLOWED, "method not allowed\n"; headers = [header.ALLOW => join(unique(allowed), ", ")])
end
#= end =#

#= snippet: routes =#
const USERS = Dict(1 => "ada", 2 => "grace")

function show_user(req, params)
    id = tryparse(Int, params["id"])
    name = id === nothing ? nothing : get(USERS, id, nothing)
    name === nothing && return Response(StatusCodes.NOT_FOUND, "no such user\n")
    Response(StatusCodes.OK, "$name\n")
end

const app = Router()
route!(app, Methods.GET, "/", (req, _) -> Response(StatusCodes.OK, "home\n"))
route!(app, Methods.GET, "/users", (req, _) -> Response(StatusCodes.OK, join(values(USERS), "\n") * "\n"))
route!(app, Methods.GET, "/users/:id", show_user)
route!(app, Methods.DELETE, "/users/:id", (req, p) -> Response(StatusCodes.NO_CONTENT))
route!(app, Methods.GET, "/users/:id/posts/:post", (req, p) -> Response(StatusCodes.OK, "post $(p["post"]) of user $(p["id"])\n"))

serve(app, "127.0.0.1", 8080)
#= end =#
