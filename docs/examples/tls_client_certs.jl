using Facil

tls = TLSConfig(get(ENV, "TLS_CERT", "cert.pem"), get(ENV, "TLS_KEY", "key.pem");
                client_ca = get(ENV, "TLS_CLIENT_CA", "clients_ca.pem"),   # certificates must be signed by this CA
                require_client_cert = true)                                # and every client must present one

serve("127.0.0.1", 8443; tls) do req
    Response(StatusCodes.OK, "hello, trusted client\n")
end
