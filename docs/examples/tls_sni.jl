using Facil

certs = get(ENV, "TLS_DIR", "certs")
pem(name) = joinpath(certs, name)

# The default certificate answers every name that has no entry in `sni`.
tls = TLSConfig(get(ENV, "TLS_CERT", "cert.pem"), get(ENV, "TLS_KEY", "key.pem");
                # (host, cert, key) or (host, cert, key, password); the host may be a wildcard
                sni = [("a.test", pem("a_cert.pem"), pem("a_key.pem")),
                       ("*.b.test", pem("b_cert.pem"), pem("b_key.pem"))],
                min_version = v"1.2",
                prefer_server_ciphers = true)

serve("127.0.0.1", 8443; tls) do req
    # The name the client asked for is not passed to the handler; use the Host header.
    Response(StatusCodes.OK, "hello " * as_str(get(headers(req), header.HOST, hv"?")) * "\n")
end
