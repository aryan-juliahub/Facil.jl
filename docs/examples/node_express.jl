using Facil, JSON

# ---- a few lines that stand in for Express ----

json(data; status = StatusCodes.OK) =                       # res.status(s).json(data)
    Response(status, JSON.json(data); headers = [header.CONTENT_TYPE => "application/json"])

struct Route
    method::HttpMethod
    segments::Vector{String}                                # "/users/:id" -> ["users", ":id"]
    handler::Function
end

const ROUTES = Route[]
route(handler, m::HttpMethod, pattern::String) =            # app.get(pattern, handler)
    push!(ROUTES, Route(m, split(pattern, '/'; keepempty = false), handler))

function match_route(r::Route, segments)
    length(r.segments) == length(segments) || return nothing
    params = Dict{String,String}()
    for (pattern, value) in zip(r.segments, segments)
        if startswith(pattern, ':')
            params[pattern[2:end]] = value                  # req.params
        elseif pattern != value
            return nothing
        end
    end
    params
end

function router(req)
    segments = split(path(uri(req)), '/'; keepempty = false)
    for r in ROUTES
        r.method == method(req) || continue
        params = match_route(r, segments)
        params === nothing || return r.handler(req, params)
    end
    json(Dict("error" => "not found"); status = StatusCodes.NOT_FOUND)
end

# Middleware is a function that takes a handler and returns a handler.
function logger(next)                                       # app.use((req, res, next) => ...)
    function (req)
        res = next(req)
        println(method(req), ' ', uri(req), " -> ", Int(status(res)))
        res
    end
end

# ---- the application ----

const USERS = Dict(1 => "ada", 2 => "grace")
const USERS_LOCK = ReentrantLock()                          # handlers run on several threads

route(Methods.GET, "/users") do req, params
    json(lock(() -> [Dict("id" => id, "name" => name) for (id, name) in sort!(collect(USERS))], USERS_LOCK))
end

route(Methods.GET, "/users/:id") do req, params
    id = tryparse(Int, params["id"])
    name = id === nothing ? nothing : lock(() -> get(USERS, id, nothing), USERS_LOCK)
    name === nothing && return json(Dict("error" => "no such user"); status = StatusCodes.NOT_FOUND)
    json(Dict("id" => id, "name" => name))
end

route(Methods.POST, "/users") do req, params
    data = try
        JSON.parse(body(req))                               # express.json()
    catch
        return json(Dict("error" => "invalid JSON"); status = StatusCodes.BAD_REQUEST)
    end
    data isa AbstractDict && get(data, "name", nothing) isa AbstractString ||
        return json(Dict("error" => "name is required"); status = StatusCodes.BAD_REQUEST)
    id = lock(USERS_LOCK) do
        id = maximum(keys(USERS); init = 0) + 1
        USERS[id] = data["name"]
        id
    end
    json(Dict("id" => id, "name" => data["name"]); status = StatusCodes.CREATED)
end

serve(logger(router), "127.0.0.1", 8080)                    # app.listen(8080)
