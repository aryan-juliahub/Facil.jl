using Facil

const ROOT = get(ENV, "SITE_ROOT", @__DIR__)
const PUBLIC = joinpath(ROOT, "public")      # served as is: /app.css -> public/app.css
const REPORTS = joinpath(ROOT, "reports")    # private: sent only by the handler

Facil.register_mime!("geojson", "application/geo+json")

function app(req)
    p = path(uri(req))
    if startswith(p, "/reports/")
        name = chopprefix(p, "/reports/")
        # Never build a file path from request text without checking it.
        occursin(r"^[A-Za-z0-9_-]+\.csv$", name) || return Response(StatusCodes.BAD_REQUEST, "bad report name\n")
        sendfile(joinpath(REPORTS, name); headers = [header.CONTENT_DISPOSITION => "attachment"])
    else
        Response(StatusCodes.NOT_FOUND, "no such page\n")
    end
end

serve(app, "127.0.0.1", 8080; public_folder = PUBLIC)
