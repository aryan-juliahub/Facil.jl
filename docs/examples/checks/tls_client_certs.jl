# mode: process
# env: TLS_CERT=@repo/test/certs/rsa_cert.pem TLS_KEY=@repo/test/certs/rsa_key.pem TLS_CLIENT_CA=@repo/test/certs/ca_cert.pem
certs = joinpath(pkgdir(Facil), "test", "certs")
c(name) = joinpath(certs, name)
url = "https://127.0.0.1:$(ex.port)/"
@test curl("--cacert", c("rsa_cert.pem"), "--cert", c("client_cert.pem"), "--key", c("client_key.pem"), url) == "hello, trusted client\n"
# No client certificate.
@test read(ignorestatus(`curl -s --max-time 10 --cacert $(c("rsa_cert.pem")) $url`), String) == ""
# A certificate the CA did not sign.
@test read(ignorestatus(`curl -s --max-time 10 --cacert $(c("rsa_cert.pem")) --cert $(c("stranger_cert.pem")) --key $(c("stranger_key.pem")) $url`), String) == ""
