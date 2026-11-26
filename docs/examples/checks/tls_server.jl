# mode: process
# env: TLS_CERT=@repo/test/certs/rsa_cert.pem TLS_KEY=@repo/test/certs/rsa_key.pem
ca = joinpath(pkgdir(Facil), "test", "certs", "rsa_cert.pem")
url = "https://127.0.0.1:$(ex.port)/"
@test curl("--cacert", ca, url) == "secure hello\n"
# Without the certificate as a trusted root the client refuses the connection.
@test !success(`curl -s --max-time 10 $url`)
# TLS 1.1 is below min_version.
@test !success(`curl -s --max-time 10 --cacert $ca --tls-max 1.1 $url`)
# Plain HTTP on the HTTPS port gets no HTTP answer.
@test !success(`curl -s --max-time 10 http://127.0.0.1:$(ex.port)/`)
