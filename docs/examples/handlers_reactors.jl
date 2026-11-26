using Facil

serve("127.0.0.1", 8080; inline = true, reactors = 4) do req
    Response(StatusCodes.OK, "hello from a reactor thread")
end
