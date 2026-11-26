using Facil

# A slow job: on the reactor thread it would stall every connection.
function resize_image(bytes::Vector{UInt8})
    Facil.sleep(0.2)
    reverse(bytes)
end

function on_message(ws, msg)
    if msg isa Vector{UInt8}
        send(ws, resize_image(msg))
    else
        send(ws, "send a binary message")
    end
end

serve("127.0.0.1", 8080) do req
    websocket(req; on_message, spawn = true, max_message_size = 8 * 1024 * 1024, subprotocol = "resize.v1")
end
