using Facil, SHA

# One hashing context per upload: before_body runs once per request, so the
# closure it returns belongs to that request alone.
mutable struct Upload
    ctx::SHA.SHA256_CTX
    bytes::Int
end

const UPLOADS = Dict{String,Upload}()
const UPLOADS_LOCK = ReentrantLock()

function choose(head)
    id = get(headers(head), "x-upload-id", nothing)
    id === nothing && return Reject(400)
    up = Upload(SHA.SHA256_CTX(), 0)
    lock(() -> UPLOADS[String(id)] = up, UPLOADS_LOCK)
    Stream() do chunk            # runs on the reactor thread: must not block
        SHA.update!(up.ctx, chunk)
        up.bytes += length(chunk)
    end
end

serve("127.0.0.1", 8080; before_body = choose, max_body_size = 1024^3) do req
    id = get(headers(req), "x-upload-id", nothing)
    up = id === nothing ? nothing : lock(() -> pop!(UPLOADS, String(id), nothing), UPLOADS_LOCK)
    up === nothing && return Response(StatusCodes.BAD_REQUEST, "send a body and an x-upload-id header\n")
    Response(StatusCodes.OK, "$(up.bytes) bytes, sha256 $(bytes2hex(SHA.digest!(up.ctx)))\n")
end
