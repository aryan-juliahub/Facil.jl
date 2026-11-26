certs = joinpath(pkgdir(Facil), "test", "certs")
dir = mktempdir()
cert, key = joinpath(dir, "cert.pem"), joinpath(dir, "key.pem")
cp(joinpath(certs, "ec_cert.pem"), cert); cp(joinpath(certs, "ec_key.pem"), key)
server = Facil.serve!(req -> "secure hello\n", "127.0.0.1", 0; tls = TLSConfig(cert, key))
subject() = read(pipeline(ignorestatus(`openssl s_client -connect 127.0.0.1:$(port(server)) -servername localhost`); stdin = devnull, stderr = devnull), String)
try
    timer = example.watch_certificate(server, cert, key; interval_ms = 50)
    @test curl("--cacert", cert, "https://127.0.0.1:$(port(server))/") == "secure hello\n"
    @test !occursin(r"O ?= ?renewed", subject())
    # A key that does not match: nothing changes, the server keeps its certificate.
    Base.sleep(1.1)
    cp(joinpath(certs, "renewed_cert.pem"), cert; force = true)
    Base.sleep(0.3)
    @test !occursin(r"O ?= ?renewed", subject())
    cp(joinpath(certs, "renewed_key.pem"), key; force = true)
    Base.sleep(1.1); touch(cert)
    @test wait_until(() -> occursin(r"O ?= ?renewed", subject()); timeout = 5)
    @test curl("--cacert", cert, "https://127.0.0.1:$(port(server))/") == "secure hello\n"
    close(server); wait(server)
    @test wait_until(() -> !isopen(timer); timeout = 5)
    # reload! errors
    @test_throws ArgumentError reload!(server; cert, key)
finally
    close(server)
end
plain = Facil.serve!(req -> "x", "127.0.0.1", 0)
@test_throws ArgumentError reload!(plain; cert, key)
close(plain)
@test_throws TLSError TLSConfig(joinpath(certs, "ec_cert.pem"), joinpath(certs, "rsa_key.pem"))
@test_throws ArgumentError TLSConfig("missing.pem", "missing.pem")
@test_throws TLSError TLSConfig(joinpath(certs, "rsa_cert.pem"), joinpath(certs, "rsa_key_enc.pem"); password = "wrong")
@test TLSConfig(joinpath(certs, "rsa_cert.pem"), joinpath(certs, "rsa_key_enc.pem"); password = "secret") isa TLSConfig
@test_throws ArgumentError TLSConfig(joinpath(certs, "ec_cert.pem"), joinpath(certs, "ec_key.pem"); require_client_cert = true)
@test_throws ArgumentError Facil.serve!(req -> "x", "127.0.0.1", 0; tls = TLSConfig(joinpath(certs, "ec_cert.pem"), joinpath(certs, "ec_key.pem")), reactors = 2)
