using Facil

# Reloads the certificate whenever its file changes (for example after a
# renewal by certbot). Checks once a minute; returns the timer.
function watch_certificate(server::Server, cert::AbstractString, key::AbstractString; interval_ms = 60_000)
    seen = Ref(mtime(cert))
    every(interval_ms) do
        isopen(server) || return false          # stop with the server
        m = mtime(cert)
        m == seen[] && return true
        try
            reload!(server; cert, key)          # new connections get the new certificate
            seen[] = m
            println(stderr, "certificate reloaded")
        catch e
            # A bad pair (say, the key is not written yet) changes nothing; try again next time.
            println(stderr, "certificate not reloaded: ", sprint(showerror, e))
        end
        true
    end
end

function main()
    cert = get(ENV, "TLS_CERT", "cert.pem")
    key = get(ENV, "TLS_KEY", "key.pem")
    server = serve!("127.0.0.1", 8443; tls = TLSConfig(cert, key)) do req
        Response(StatusCodes.OK, "secure hello\n")
    end
    watch_certificate(server, cert, key)
    wait(server)
end

abspath(PROGRAM_FILE) == @__FILE__() && main()
