using Facil

# What the application keeps for each connection, stored in `ws.data`.
mutable struct Session
    name::String
    messages::Int
end

function on_open(ws)
    ws.data = Session("guest", 0)
    send(ws, "hello guest; send `/name NAME` to rename yourself")
end

function on_message(ws, msg)
    session = ws.data::Session
    msg isa String || return close(ws; code = 1003, reason = "text only")
    session.messages += 1
    if startswith(msg, "/name ")
        session.name = strip(chopprefix(msg, "/name "))
        send(ws, "you are now $(session.name)")
    elseif msg == "/quit"
        close(ws; code = 1000, reason = "bye")
    else
        send(ws, "$(session.name) #$(session.messages): $msg")
    end
end

on_close(ws) = println(stderr, ws.data.name, " left after ", ws.data.messages, " messages")

serve("127.0.0.1", 8080) do req
    path(uri(req)) == "/ws" || return Response(StatusCodes.NOT_FOUND, "not found")
    websocket(req; on_open, on_message, on_close, max_message_size = 64 * 1024)
end
