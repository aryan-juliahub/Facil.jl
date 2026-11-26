using Facil

# A CSV export that never holds more than one batch of rows in memory.
# `rows` stands in for a database cursor.
rows(n) = (string(i, ",", "user", i, ",", i % 7, "\n") for i in 1:n)

function export_csv(req)
    n = something(tryparse(Int, something(query(uri(req)), "")), 100_000)
    hs = [header.CONTENT_TYPE => "text/csv; charset=utf-8",
          header.CONTENT_DISPOSITION => "attachment; filename=\"users.csv\""]
    stream(req; headers = hs, high_water = 256 * 1024) do io
        write(io, "id,name,group\n")
        buf = IOBuffer()
        for (i, row) in enumerate(rows(n))
            write(buf, row)
            if i % 1000 == 0
                isopen(io) || return          # the client went away: stop producing
                write(io, take!(buf))         # blocks while the client is slow
            end
        end
        write(io, take!(buf))
    end
end

serve(export_csv, "127.0.0.1", 8080)
