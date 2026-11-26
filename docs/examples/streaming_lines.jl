using Facil

serve("127.0.0.1", 8080) do req
    stream(req; headers = [header.CONTENT_TYPE => "text/plain; charset=utf-8"]) do io
        for i in 1:5
            write(io, "line $i\n")
            flush(io)                 # send now instead of waiting for more
            Facil.sleep(0.1)
        end
    end
end
