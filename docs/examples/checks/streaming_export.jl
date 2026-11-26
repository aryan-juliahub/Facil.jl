r = http(ex, "GET", "/?2500")
@test r.status == 200 && r.headers["content-disposition"] == "attachment; filename=\"users.csv\""
lines = split(r.body, "\n"; keepempty = false)
@test length(lines) == 2501 && lines[1] == "id,name,group" && lines[end] == "2500,user2500,1"
@test count(==('\n'), http(ex, "GET", "/").body) == 100_001
# A client that leaves early does not keep a stream alive.
s = connect("127.0.0.1", ex.port)
write(s, "GET /?50000000 HTTP/1.1\r\nHost: x\r\n\r\n")
readuntil(s, "id,name,group\n")
close(s)
@test wait_until(() -> Facil.live_streams() == 0; timeout = 20)
