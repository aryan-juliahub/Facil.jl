# Other examples in this process may still hold streams of their own.
streams_before = Facil.live_streams()
c = sse_open(ex, "/events")
@test startswith(c.head, "HTTP/1.1 200") && occursin("content-type:text/event-stream", c.head)
@test occursin("cache-control:no-cache", c.head)
@test sse_next(c) == Dict("retry" => "2000")
for i in 1:5
    @test sse_next(c) == Dict("event" => "tick", "id" => "$i", "data" => "tick $i")
end
@test sse_next(c) == Dict("event" => "done", "data" => "bye")
@test eof(c.sock)
# Reconnecting with Last-Event-ID resumes after that event.
c = sse_open(ex, "/events"; headers = ["Last-Event-ID" => "3"])
sse_next(c)
@test sse_next(c)["data"] == "tick 4"
@test sse_next(c)["data"] == "tick 5"
close(c.sock)
@test http(ex, "GET", "/other").status == 404
@test wait_until(() -> Facil.live_streams() <= streams_before)
# The browser snippet in the guide, run under Node.js when it has EventSource (22.3 or later).
node = Sys.which("node")
if node !== nothing && success(pipeline(`$node --experimental-eventsource -e "EventSource"`; stdout = devnull, stderr = devnull))
    page = read(joinpath(dirname(dirname(@__DIR__)), "src", "guide", "sse.md"), String)
    js = match(r"```js\n(.*?)```"s, page)[1]
    js = replace(js, "\"/events\"" => "\"$(base_url(ex))/events\"")
    out = read(pipeline(`$node --experimental-eventsource -e $js`; stderr = devnull), String)
    @test out == join(["$i tick $i\n" for i in 1:5])
else
    @info "sse_ticks: node with EventSource not found; the browser snippet was not run"
end
