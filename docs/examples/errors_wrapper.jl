using Facil

# An error a handler throws on purpose, with the status the client should get.
struct HttpProblem <: Exception
    status::StatusCode
    message::String
end

const REQUEST_ID = Threads.Atomic{Int}(0)

# Turns anything the handler throws into a response, so Facil's plain 500 is
# never reached. Unexpected errors are logged in full with a request id that
# the client also sees.
function with_errors(handler)
    function (req)
        try
            handler(req)
        catch e
            if e isa HttpProblem
                Response(e.status, e.message * "\n")
            else
                id = Threads.atomic_add!(REQUEST_ID, 1) + 1
                @error "request $id failed" method = method(req) target = string(uri(req)) exception = (e, catch_backtrace())
                Response(StatusCodes.INTERNAL_SERVER_ERROR, "internal error, request id $id\n")
            end
        end
    end
end

# One line per request: method, target, status, milliseconds.
function with_access_log(handler; io::IO = stdout)
    function (req)
        t = time()
        res = handler(req)
        code = res isa Response ? Int(status(res)) : 200
        println(io, method(req), ' ', uri(req), ' ', code, ' ', round((time() - t) * 1000; digits = 1), " ms")
        res
    end
end

function app(req)
    p = path(uri(req))
    if p == "/users/1"
        Response(StatusCodes.OK, "ada\n")
    elseif startswith(p, "/users/")
        throw(HttpProblem(StatusCodes.NOT_FOUND, "no such user"))
    elseif p == "/bug"
        parse(Int, "not a number")
    else
        throw(HttpProblem(StatusCodes.NOT_FOUND, "not found"))
    end
end

serve(with_access_log(with_errors(app)), "127.0.0.1", 8080)
