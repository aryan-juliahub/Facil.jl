using Facil

# Paths to a PEM certificate (chain, leaf first) and its private key.
cert = get(ENV, "TLS_CERT", "cert.pem")
key = get(ENV, "TLS_KEY", "key.pem")

# Reads and checks both files now: a missing file, a wrong password or a key
# that does not match the certificate throws here, before the server starts.
tls = TLSConfig(cert, key; min_version = v"1.2")

serve("127.0.0.1", 8443; tls) do req
    Response(StatusCodes.OK, "secure hello\n")
end
