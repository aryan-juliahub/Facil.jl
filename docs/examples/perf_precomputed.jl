using Facil

# Built once. Facil sends a body without copying it, and the same String may be
# in flight to any number of clients at once.
const INDEX = "<!doctype html><title>Shop</title><h1>Welcome</h1>\n" * "<p>catalogue</p>\n"^200
const HTML = [header.CONTENT_TYPE => "text/html; charset=utf-8", header.CACHE_CONTROL => "max-age=60"]
const NOT_FOUND = "not found\n"

serve("127.0.0.1", 8080; inline = true) do req
    path(uri(req)) == "/" ? Response(StatusCodes.OK, INDEX; headers = HTML) :
                            Response(StatusCodes.NOT_FOUND, NOT_FOUND)
end
