# mode: process
c = ws_connect(ex, "/ticks")
m1 = ws_recv(c)
m2 = ws_recv(c)
@test startswith(m1, "tick ")
@test parse(Int, m2[6:end]) == parse(Int, m1[6:end]) + 1
@test http(ex, "GET", "/stats").body == "dropped=0 closed=0"
ws_send(c, "stop")
Base.sleep(0.3)
# Nothing arrives after the unsubscribe: drain what was in flight, then expect silence.
t = @async try
    while true
        ws_recv(c; timeout = 0.4)
    end
catch
    :silent
end
@test fetch(t) === :silent
ws_close(c)
