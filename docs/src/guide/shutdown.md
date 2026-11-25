# Shutting down

`serve` blocks until the server is closed. Ctrl-C closes it.

`serve!` returns a `Server` at once. `close(server)` stops accepting connections
and closes open ones once their queued output is sent; `wait(server)` blocks until
it has stopped. Stopping takes up to about one second.

`close(server; grace = seconds)` lets requests in progress finish first: it
stops accepting, closes idle connections, lets each running request reply (that
reply closes its connection), and closes whatever is left after `grace` seconds.

```julia
using Facil

server = serve!("127.0.0.1", 8080) do req
    Facil.sleep(1.0)
    Response(StatusCodes.OK, "done")
end

Facil.Timer(_ -> close(server; grace = 5), 0.5)
wait(server)
println(stderr, "server closed")
```

## SIGTERM

For a process running `serve` in the foreground, SIGTERM does the same drain: open
requests get up to `shutdown_grace` seconds (default 10) to finish, then the
process exits.

```julia
using Facil

serve("127.0.0.1", 8080; shutdown_grace = 5) do req
    Facil.sleep(1.0)
    Response(StatusCodes.OK, "finished")
end
```

```
$ curl -s localhost:8080/ & sleep 0.3; kill -TERM <pid>
finished
```

The reactor itself stays alive for the life of the process; closing a server
closes only its listener and connections.
