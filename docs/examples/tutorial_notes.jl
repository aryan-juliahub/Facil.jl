using Facil, JSON

#= snippet: storage =#
struct Note
    id::Int
    title::String
    text::String
end

const NOTES = Dict{Int,Note}()
const NOTES_LOCK = ReentrantLock()
const NEXT_ID = Ref(1)
#= end =#

#= snippet: helpers =#
const JSON_TYPE = [header.CONTENT_TYPE => "application/json"]

json(status, data) = Response(status, JSON.json(data); headers = JSON_TYPE)
problem(status, message) = json(status, (error = message,))
#= end =#

#= snippet: list =#
function list_notes(req)
    q = lowercase(query_param(req, "q"; default = ""))
    notes = lock(NOTES_LOCK) do
        sort!([n for n in values(NOTES) if occursin(q, lowercase(n.title))]; by = n -> n.id)
    end
    json(StatusCodes.OK, notes)
end
#= end =#

#= snippet: create =#
function create_note(req)
    data = try
        JSON.parse(body(req))
    catch
        return problem(StatusCodes.BAD_REQUEST, "the body is not valid JSON")
    end
    data isa AbstractDict || return problem(StatusCodes.BAD_REQUEST, "expected a JSON object")
    title = get(data, "title", nothing)
    title isa AbstractString && !isempty(title) ||
        return problem(StatusCodes.UNPROCESSABLE_ENTITY, "title is required")
    text = get(data, "text", "")
    text isa AbstractString || return problem(StatusCodes.UNPROCESSABLE_ENTITY, "text must be a string")
    note = lock(NOTES_LOCK) do
        id = NEXT_ID[]
        NEXT_ID[] += 1
        NOTES[id] = Note(id, title, text)
    end
    Response(StatusCodes.CREATED, JSON.json(note);
             headers = [header.CONTENT_TYPE => "application/json", header.LOCATION => "/notes/$(note.id)"])
end
#= end =#

#= snippet: one =#
function get_note(id)
    note = lock(() -> get(NOTES, id, nothing), NOTES_LOCK)
    note === nothing ? problem(StatusCodes.NOT_FOUND, "no note $id") : json(StatusCodes.OK, note)
end

function delete_note(id)
    found = lock(() -> pop!(NOTES, id, nothing), NOTES_LOCK)
    found === nothing ? problem(StatusCodes.NOT_FOUND, "no note $id") : Response(StatusCodes.NO_CONTENT)
end
#= end =#

#= snippet: router =#
not_allowed(allow) = Response(StatusCodes.METHOD_NOT_ALLOWED, JSON.json((error = "method not allowed",));
                              headers = [header.CONTENT_TYPE => "application/json", header.ALLOW => allow])

function app(req)
    m, p = method(req), path(uri(req))
    if p == "/notes"
        m == Methods.GET && return list_notes(req)
        m == Methods.POST && return create_note(req)
        return not_allowed("GET, POST")
    end
    found = match(r"^/notes/(\d+)$", p)
    if found !== nothing
        id = parse(Int, found[1])
        m == Methods.GET && return get_note(id)
        m == Methods.DELETE && return delete_note(id)
        return not_allowed("GET, DELETE")
    end
    p == "/health" && return Response(StatusCodes.OK, "ok")
    problem(StatusCodes.NOT_FOUND, "no such route")
end
#= end =#

#= snippet: main =#
if abspath(PROGRAM_FILE) == @__FILE__
    serve(app, "127.0.0.1", 8080; max_body_size = 64 * 1024)
end
#= end =#
