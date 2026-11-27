# [HTTPS (TLS)](@id tls-guide)

This page shows how to serve HTTPS: building a [`TLSConfig`](@ref), choosing
certificates by host name, requiring client certificates, and replacing a
certificate while the server runs. Everything else on a server (handlers,
streaming, WebSockets as `wss://`) works the same over TLS.

Facil uses OpenSSL 3 through Julia's own `OpenSSL_jll`; you do not install
anything.

## A certificate for development

For local work, make a self-signed certificate with the `openssl` command:

```sh
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 365 \
    -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
```

This writes `cert.pem` and an unencrypted `key.pem`. Browsers and clients will
not trust it unless you tell them to (`curl --cacert cert.pem`). For a public
server, get a certificate from a certificate authority, for example with an
ACME client such as certbot.

## Serve HTTPS

Build a `TLSConfig` from the certificate and key and pass it as `tls`:

```@eval
Main.example("tls_server.jl")
```

```sh
$ curl --cacert cert.pem https://127.0.0.1:8443/
secure hello
```

`cert` and `key` are each a file path or the PEM text itself (anything
containing `-----BEGIN `). The certificate may hold the whole chain, leaf
first, then intermediates.

A server is either HTTP or HTTPS. To serve both, start two servers; they share
the reactor:

- one with `tls` on 443,
- one without on 80 whose handler redirects to `https://`.

A plain-HTTP request sent to the HTTPS port fails the TLS handshake and gets no
HTTP answer.

!!! note "HTTPS needs `reactors = 1`"
    TLS connections are only safe on one reactor thread. `serve!` with `tls`
    and `reactors > 1` throws an `ArgumentError`, and so does an HTTPS server
    in a process whose reactor already runs several threads. Handlers still
    run on all Julia threads (`inline = false`); only socket I/O and
    encryption are on the single reactor thread.

## Errors show up early

`TLSConfig` reads the files and checks every certificate against its key when
you construct it, not at the first connection. What it throws:

| Problem | Exception |
|---|---|
| File missing, or it holds no PEM data | `ArgumentError` |
| Key does not match the certificate | [`TLSError`](@ref) |
| Encrypted key, wrong or missing `password` | [`TLSError`](@ref) |
| OpenSSL rejects the versions, `ciphers` or `ciphersuites` | [`TLSError`](@ref) |
| `require_client_cert = true` without `client_ca` | `ArgumentError` |
| `max_version` below `min_version`, or not a TLS version | `ArgumentError` |

A `TLSError` message carries OpenSSL's own reason, for example
`TLSError: certificate: the private key does not match the certificate
(error:05800074:x509 certificate routines::key values mismatch)`.

Because the files are read at construction, a `TLSConfig` keeps working if the
files are later moved or deleted, and does not notice when they change. See
[Replace a certificate](tls.md#Replace-a-certificate-without-restarting).

## Options

| Keyword | Default | Meaning |
|---|---|---|
| `password` | `nothing` | Passphrase of an encrypted key. Also used for `sni` entries that give none. |
| `sni` | `[]` | Extra certificates chosen by host name; see below. |
| `min_version` | `v"1.2"` | Lowest protocol version accepted: `v"1.0"`, `v"1.1"`, `v"1.2"` or `v"1.3"`. |
| `max_version` | `nothing` | Highest version accepted; `nothing` means the newest OpenSSL supports. |
| `ciphers` | `nothing` | OpenSSL cipher list for TLS 1.2 and below. `nothing` keeps OpenSSL's default. |
| `ciphersuites` | `nothing` | Cipher suites for TLS 1.3. |
| `prefer_server_ciphers` | `false` | Use the server's cipher order instead of the client's. |
| `client_ca` | `nothing` | CA certificates (path or PEM) that client certificates must chain to. |
| `require_client_cert` | `false` | Refuse clients that present no certificate. Needs `client_ca`. |

Keep `min_version` at `v"1.2"` or raise it to `v"1.3"`. TLS 1.0 and 1.1 are
obsolete; with OpenSSL 3 they also need `ciphers = "DEFAULT@SECLEVEL=0"` to
work at all.

The server offers only `http/1.1` through ALPN. There is no HTTP/2.

## Several certificates (SNI)

One server can present different certificates depending on the host name the
client asks for. Each `sni` entry is `(host, cert, key)` or
`(host, cert, key, password)`. `host` may be a wildcard such as `"*.b.test"`.
Names without an entry get the default certificate.

```@eval
Main.example("tls_sni.jl")
```

The handler does not receive the negotiated name. Route on the `Host` header,
which clients send with the same name.

## Client certificates (mutual TLS)

Give `client_ca` to verify the certificates clients present. A client whose
certificate was not signed by that CA is refused during the handshake. With
`require_client_cert = true`, a client that presents no certificate is refused
too; without it, such clients are let in.

```@eval
Main.example("tls_client_certs.jl")
```

```sh
$ curl --cacert cert.pem --cert client_cert.pem --key client_key.pem https://127.0.0.1:8443/
hello, trusted client
```

A refused client sees a failed handshake, not an HTTP status, and your handler
is not called. To tell admitted clients apart, [`client_certificate`](@ref)`(req)`
is the certificate the client presented, as PEM text (`nothing` for a client
without one); parse it with an X.509 package for the subject or compute its
fingerprint.

## Replace a certificate without restarting

[`reload!`](@ref)`(server; cert, key)` swaps the certificate of a running
HTTPS server. Connections made from then on get the new certificate; open
connections keep the one they started with. If the pair is bad, `reload!`
throws (as `TLSConfig` would) and the server keeps its current certificate.

- `host = "name"` replaces the `sni` entry of that name, or adds one. Without
  `host`, the default certificate is replaced.
- `password` unlocks an encrypted key.
- On a server without `tls`, or one that is closed, `reload!` throws an
  `ArgumentError`.

Certificates are usually renewed by another program that rewrites the files.
This example checks the certificate file once a minute and reloads when it
changed:

```@eval
Main.example("tls_reload.jl")
```

The renewal tool may write the certificate and the key a moment apart. The
watcher handles that: a mismatched pair makes `reload!` throw, nothing changes,
and the next check tries again.

## Behind a reverse proxy

If nginx, Caddy or a load balancer terminates TLS in front of Facil, serve
plain HTTP on a loopback or private address and leave certificates to the
proxy. See [Deployment](deployment.md).

## See also

- [Security notes](security.md).
- [Graceful shutdown](shutdown.md).
- API: [`TLSConfig`](@ref), [`TLSError`](@ref), [`reload!`](@ref).
