using Facil

serve("127.0.0.1", 8080) do req
    stream(req; headers = [header.CONTENT_TYPE => "text/plain"]) do io
        for i in 1:3
            write(io, "line $i\n")
        end
    end
end
