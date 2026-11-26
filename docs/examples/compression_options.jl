using Facil

# gzip and brotli only, harder compression, from 256 bytes up, and never for
# server-sent JSON that a legacy client cannot decode.
opts = CompressOptions(prefer = (:br, :gzip), gzip = 9, br = 6, min_size = 256,
                       compressible = type -> Facil.compressible_type(type) && !startswith(type, "application/x-legacy"))

const DATA = "[" * join(("{\"id\":$i,\"name\":\"item $i\"}" for i in 1:200), ",") * "]"
const PRECOMPRESSED = Facil.zstd(DATA; level = 19)     # compressed once, at start-up

serve("127.0.0.1", 8080; compress = opts) do req
    p = path(uri(req))
    if p == "/items"
        Response(StatusCodes.OK, DATA; headers = [header.CONTENT_TYPE => "application/json"])
    elseif p == "/legacy"
        Response(StatusCodes.OK, DATA; headers = [header.CONTENT_TYPE => "application/x-legacy+json"])
    elseif p == "/exact"
        Response(StatusCodes.OK, DATA; headers = [header.CONTENT_TYPE => "application/json",
                                                  header.CACHE_CONTROL => "no-transform"])
    elseif p == "/archive"
        # Already encoded: Facil leaves a response with content-encoding alone.
        Response(StatusCodes.OK, PRECOMPRESSED; headers = [header.CONTENT_TYPE => "application/json",
                                                           header.CONTENT_ENCODING => "zstd"])
    elseif p == "/live"
        stream(req; compress = :gzip, headers = [header.CONTENT_TYPE => "text/plain"]) do io
            for i in 1:3
                write(io, "update $i\n")
                flush(io)              # ends a compressed block so the client can read it now
            end
        end
    else
        Response(StatusCodes.NOT_FOUND)
    end
end
