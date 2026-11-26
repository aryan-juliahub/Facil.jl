# mode: process
# env: TLS_DIR=@repo/test/certs TLS_CERT=@repo/test/certs/rsa_cert.pem TLS_KEY=@repo/test/certs/rsa_key.pem
certs = joinpath(pkgdir(Facil), "test", "certs")
subject(name) = read(pipeline(ignorestatus(`openssl s_client -connect 127.0.0.1:$(ex.port) -servername $name`); stdin = devnull, stderr = devnull), String)
@test occursin("CN=a.test", subject("a.test"))
@test occursin("CN=b.test", subject("www.b.test"))
@test occursin("CN=localhost", subject("other.example"))
p = ex.port
@test curl("--cacert", joinpath(certs, "a_cert.pem"), "--resolve", "a.test:$p:127.0.0.1", "https://a.test:$p/") == "hello a.test:$p\n"
@test curl("--cacert", joinpath(certs, "b_cert.pem"), "--resolve", "www.b.test:$p:127.0.0.1", "https://www.b.test:$p/") == "hello www.b.test:$p\n"
