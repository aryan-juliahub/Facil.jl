# Run by PackageCompiler while it builds the sysimage: start the app, send it
# one request per route so their code is compiled into the image, and stop.
using Facil
import Downloads

include(joinpath(@__DIR__, "deploy_app_routes.jl"))

server = serve!(app, "127.0.0.1", 0)
for target in ("/health", "/", "/missing")
    Downloads.request("http://127.0.0.1:$(port(server))$target"; output = devnull, throw = false)
end
close(server)
wait(server)
