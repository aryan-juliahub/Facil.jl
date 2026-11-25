# HTTPS

Pass a `TLSConfig` as `tls`:

```julia
using Facil

tls = TLSConfig("cert.pem", "key.pem"; min_version = v"1.2")
server = serve!("127.0.0.1", 8080; tls) do req
    Response(StatusCodes.OK, "secure")
end

reload!(server; cert = "new_cert.pem", key = "new_key.pem")
```

- `cert` and `key` are file paths or PEM text. `cert` may hold the whole chain,
  leaf first. `password` unlocks an encrypted key.
- The files are read and each certificate is checked against its key when the
  `TLSConfig` is built, so a missing file, a wrong password or a mismatched pair
  throws there (`ArgumentError` or `TLSError`), not at the first connection.
- `sni = [(host, cert, key), ...]` adds certificates chosen by the name the client
  asks for; `host` may be a wildcard such as `"*.example.com"`.
- `min_version`, `max_version` (`v"1.2"`, `v"1.3"`), `ciphers` (TLS 1.2),
  `ciphersuites` (TLS 1.3), `prefer_server_ciphers`.
- `client_ca` verifies client certificates; `require_client_cert = true` refuses
  clients that present none.

`reload!(server; cert, key)` replaces the certificate while the server runs:
new connections get the new one, open connections keep theirs. A bad pair
throws and changes nothing. `host = "name"` replaces or adds an SNI entry.

HTTPS servers need `reactors = 1`: TLS connections are only safe on one reactor
thread. Handlers can still run on many Julia threads (`inline = false`).
Facil links against Julia's own OpenSSL (`OpenSSL_jll`).
