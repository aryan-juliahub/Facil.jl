using Facil

serve("127.0.0.1", 8080) do req
    Response(StatusCodes.OK, "hello")
end
