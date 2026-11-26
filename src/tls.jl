# HTTPS: TLSConfig describes certificates and protocol settings; serve!(...; tls)
# builds a facil.io TLS object from it for each server, and reload! swaps a
# server's certificate in place.

const TLS_VERSIONS = Dict(v"1.0" => 0x0301, v"1.1" => 0x0302, v"1.2" => 0x0303, v"1.3" => 0x0304)
const TLS_SERVER_PREFERENCE = 1
const TLS_REQUIRE_PEER_CERT = 2

"""
    TLSConfig(cert, key; password = nothing, sni = [], min_version = v"1.2",
              max_version = nothing, ciphers = nothing, ciphersuites = nothing,
              prefer_server_ciphers = false, client_ca = nothing,
              require_client_cert = false)

The certificate and TLS settings of an HTTPS server. Pass it to
[`serve!`](@ref) as `tls`.

# Arguments
- `cert::AbstractString`: the certificate, as a file path or as PEM text. It
  may hold the whole chain, leaf first.
- `key::AbstractString`: its private key, as a file path or PEM text.

# Keywords
- `password = nothing`: the passphrase of an encrypted `key`.
- `sni = []`: more certificates, chosen by the server name the client asks for:
  tuples `(host, cert, key)` or `(host, cert, key, password)`. `host` may be a
  wildcard such as `"*.example.com"`. Clients asking for any other name, or
  none, get `cert`.
- `min_version::VersionNumber = v"1.2"`, `max_version = nothing`: the protocol
  range, from `v"1.0"`, `v"1.1"`, `v"1.2"`, `v"1.3"`; `nothing` means no upper
  bound. TLS 1.0 and 1.1 also need `ciphers = "DEFAULT@SECLEVEL=0"` with
  OpenSSL 3, and should not be used.
- `ciphers = nothing`: an OpenSSL cipher list for TLS 1.2 and below.
- `ciphersuites = nothing`: the TLS 1.3 cipher suites, colon-separated.
- `prefer_server_ciphers::Bool = false`: the server's order of ciphers wins
  over the client's.
- `client_ca = nothing`: CA certificates (file path or PEM text) to verify
  client certificates against. A client that presents a certificate not signed
  by them is refused.
- `require_client_cert::Bool = false`: also refuse clients that present no
  certificate (mutual TLS). Needs `client_ca`.

# Throws
Everything is checked when the `TLSConfig` is built, not at the first connection.
- `ArgumentError`: a file that does not exist or holds no PEM data, a
  malformed `sni` entry, an unknown version, `max_version` below `min_version`,
  `require_client_cert` without `client_ca`.
- [`TLSError`](@ref): OpenSSL refused something: an unreadable certificate, a
  wrong or missing key password, a key that does not match its certificate, a
  bad cipher string.

# Notes
- Files are read once, here. Changing them on disk afterwards has no effect;
  use [`reload!`](@ref) to rotate a certificate on a running server.
- An HTTPS server needs `reactors = 1` (the default). Handlers still run on
  all of Julia's threads.
- Facil uses the OpenSSL that ships with Julia (`OpenSSL_jll`).
- The verified client certificate is not exposed to the handler.

# Examples
The repository's test certificates stand in for your own here:

```jldoctest
julia> using Facil

julia> certs = joinpath(pkgdir(Facil), "test", "certs");

julia> tls = TLSConfig(joinpath(certs, "rsa_cert.pem"), joinpath(certs, "rsa_key.pem"); min_version = v"1.3")
TLSConfig(1 certificate(s), TLS 1.3+)

julia> server = serve!(req -> "secure", 0; tls);

julia> isopen(server)
true

julia> close(server)
```

See the [HTTPS guide](@ref tls-guide).
"""
struct TLSConfig
    cert::String
    key::String
    password::Union{Nothing,String}
    sni::Vector{NTuple{4,Union{Nothing,String}}}
    min_version::Int
    max_version::Int
    ciphers::Union{Nothing,String}
    ciphersuites::Union{Nothing,String}
    prefer_server_ciphers::Bool
    client_ca::Union{Nothing,String}
    require_client_cert::Bool
end

function TLSConfig(cert::AbstractString, key::AbstractString; password = nothing, sni = (),
                   min_version::VersionNumber = v"1.2", max_version = nothing,
                   ciphers = nothing, ciphersuites = nothing, prefer_server_ciphers::Bool = false,
                   client_ca = nothing, require_client_cert::Bool = false)
    pw = password === nothing ? nothing : no_nul(String(password), "password")
    c, k = read_pem(cert, "certificate"), read_pem(key, "key")
    entries = NTuple{4,Union{Nothing,String}}[]
    for e in sni
        (e isa Tuple && length(e) in (3, 4)) ||
            throw(ArgumentError("each sni entry must be (host, cert, key) or (host, cert, key, password)"))
        host = no_nul(String(e[1]), "sni host")
        isempty(host) && throw(ArgumentError("an sni host must not be empty"))
        epw = length(e) == 4 ? (e[4] === nothing ? nothing : no_nul(String(e[4]), "password")) : pw
        ec, ek = read_pem(e[2], "certificate for $host"), read_pem(e[3], "key for $host")
        push!(entries, (host, ec, ek, epw))
    end
    minv = tls_version(min_version, "min_version")
    maxv = max_version === nothing ? 0 : tls_version(max_version, "max_version")
    maxv != 0 && maxv < minv && throw(ArgumentError("max_version is below min_version"))
    ca = client_ca === nothing ? nothing : read_pem(client_ca, "client_ca")
    require_client_cert && ca === nothing &&
        throw(ArgumentError("require_client_cert needs client_ca, the CA client certificates are checked against"))
    ci = ciphers === nothing ? nothing : no_nul(String(ciphers), "ciphers")
    cs = ciphersuites === nothing ? nothing : no_nul(String(ciphersuites), "ciphersuites")
    cfg = TLSConfig(c, k, pw, entries, minv, maxv, ci, cs, prefer_server_ciphers, ca, require_client_cert)
    tls_free(tls_object(cfg))
    cfg
end

function Base.show(io::IO, c::TLSConfig)
    print(io, "TLSConfig(", length(c.sni) + 1, " certificate(s), TLS ", tls_name(c.min_version), "+")
    c.client_ca === nothing || print(io, c.require_client_cert ? ", client certificate required" : ", client certificates verified")
    print(io, ")")
end

tls_name(v::Integer) = (n = findfirst(==(v), TLS_VERSIONS); "$(n.major).$(n.minor)")

function tls_version(v, what)
    v isa VersionNumber || throw(ArgumentError("$what must be a VersionNumber such as v\"1.2\""))
    n = get(TLS_VERSIONS, VersionNumber(v.major, v.minor), nothing)
    n === nothing && throw(ArgumentError("$what must be one of v\"1.0\", v\"1.1\", v\"1.2\", v\"1.3\""))
    Int(n)
end

function no_nul(s::String, what)
    occursin('\0', s) && throw(ArgumentError("$what must not contain NUL"))
    s
end

# Julia strings are NUL-terminated; NUL inside was refused by no_nul.
cstr(s::Union{Nothing,String}) = s === nothing ? Ptr{UInt8}(C_NULL) : s

is_pem(s::AbstractString) = occursin("-----BEGIN ", s)

function read_pem(src, what)
    src isa AbstractString || throw(ArgumentError("$what must be a file path or PEM text"))
    s = String(src)
    is_pem(s) && return s
    isfile(s) || throw(ArgumentError("$what: no such file $(repr(s))"))
    pem = read(s, String)
    is_pem(pem) || throw(ArgumentError("$what: $(repr(s)) holds no PEM data"))
    pem
end

"""
    TLSError <: Exception

Thrown by [`TLSConfig`](@ref) and [`reload!`](@ref) when OpenSSL refuses a
certificate, a key or a setting. `e.msg` says which and carries OpenSSL's own
reason.

# Examples
```jldoctest
julia> using Facil

julia> certs = joinpath(pkgdir(Facil), "test", "certs");

julia> try
           TLSConfig(joinpath(certs, "rsa_cert.pem"), joinpath(certs, "ec_key.pem"))
       catch e
           e isa TLSError
       end
true
```
"""
struct TLSError <: Exception
    msg::String
end
Base.showerror(io::IO, e::TLSError) = print(io, "TLSError: ", e.msg)

const TLS_ERRORS = Dict(1 => "no readable certificate", 2 => "the private key could not be read (wrong or missing password?)",
                        3 => "the private key does not match the certificate", 4 => "OpenSSL rejected the setting",
                        5 => "no readable CA certificate")

function tls_check(code::Integer, what::AbstractString, err::Vector{UInt8})
    code == 0 && return nothing
    reason = unsafe_string(pointer(err))
    msg = string(what, ": ", get(TLS_ERRORS, Int(code), "error $code"), isempty(reason) ? "" : " ($reason)")
    throw(TLSError(msg))
end

function set_cert!(tls::Ptr{Cvoid}, host::String, cert::String, key::String, pw::Union{Nothing,String})
    err = zeros(UInt8, 256)
    r = GC.@preserve err @gcsafe_ccall LIBFJL.fjl_tls_set_cert(tls::Ptr{Cvoid}, host::Ptr{UInt8},
        cert::Ptr{UInt8}, sizeof(cert)::Csize_t, key::Ptr{UInt8}, sizeof(key)::Csize_t,
        cstr(pw)::Ptr{UInt8}, err::Ptr{UInt8}, length(err)::Csize_t)::Cint
    tls_check(r, isempty(host) ? "certificate" : "certificate for $host", err)
end

function tls_new()
    p = @ccall LIBFJL.fjl_tls_new()::Ptr{Cvoid}
    p == C_NULL && error("Facil: could not allocate a TLS object")
    p
end
tls_free(p::Ptr{Cvoid}) = (@ccall LIBFJL.fjl_tls_free(p::Ptr{Cvoid})::Cvoid; nothing)

# A facil.io TLS object for `cfg`; the server it is handed to owns it.
function tls_object(cfg::TLSConfig)
    tls = tls_new()
    try
        flags = (cfg.prefer_server_ciphers ? TLS_SERVER_PREFERENCE : 0) | (cfg.require_client_cert ? TLS_REQUIRE_PEER_CERT : 0)
        r = @ccall LIBFJL.fjl_tls_configure(tls::Ptr{Cvoid}, cfg.min_version::Cint, cfg.max_version::Cint,
            cstr(cfg.ciphers)::Ptr{UInt8}, cstr(cfg.ciphersuites)::Ptr{UInt8}, flags::Cint)::Cint
        r == 0 || throw(TLSError("OpenSSL rejected the protocol versions, ciphers or ciphersuites"))
        set_cert!(tls, "", cfg.cert, cfg.key, cfg.password)
        for (host, c, k, pw) in cfg.sni
            set_cert!(tls, host, c, k, pw)
        end
        if cfg.client_ca !== nothing
            ca = cfg.client_ca
            err = zeros(UInt8, 256)
            r = GC.@preserve err @ccall LIBFJL.fjl_tls_trust(tls::Ptr{Cvoid}, ca::Ptr{UInt8}, sizeof(ca)::Csize_t,
                                                               err::Ptr{UInt8}, length(err)::Csize_t)::Cint
            tls_check(r, "client_ca", err)
        end
    catch
        tls_free(tls)
        rethrow()
    end
    tls
end

const RELOAD_LOCK = ReentrantLock()

is_tls(@nospecialize(s::Server)) = s.cserver != C_NULL && (@ccall LIBFJL.fjl_tls_of(s.cserver::Ptr{Cvoid})::Ptr{Cvoid}) != C_NULL

"""
    reload!(server, cert, key; password = nothing, host = nothing) -> Server
    reload!(server; cert, key, password = nothing, host = nothing) -> Server

Replace a certificate of a running HTTPS server, without dropping connections.

# Arguments
- `server`: a [`Server`](@ref) started with `tls`.
- `cert`, `key`: the new pair, as file paths or PEM text. Files are read now.

# Keywords
- `password = nothing`: the passphrase of an encrypted `key`.
- `host = nothing`: `nothing` replaces the default certificate. A host name
  replaces that `sni` entry, or adds one if the name is new.

# Returns
`server`.

# Throws
- `ArgumentError`: the server does not serve HTTPS or is closed, a file is
  missing or not PEM, `host` is empty.
- [`TLSError`](@ref): OpenSSL refused the pair. Nothing is changed then; the
  server keeps its current certificate.

# Notes
Connections made from now on get the new certificate. Connections that are
already open keep the one they were made with. Call it from a timer or a
signal-driven task after your ACME client has renewed the files.

# Examples
```jldoctest
julia> using Facil

julia> certs = joinpath(pkgdir(Facil), "test", "certs");

julia> server = serve!(req -> "secure", 0; tls = TLSConfig(joinpath(certs, "rsa_cert.pem"), joinpath(certs, "rsa_key.pem")));

julia> reload!(server; cert = joinpath(certs, "renewed_cert.pem"), key = joinpath(certs, "renewed_key.pem")) === server
true

julia> close(server)
```
"""
reload!(s::Server; cert, key, password = nothing, host = nothing) = reload!(s, cert, key; password, host)

function reload!(@nospecialize(s::Server), cert, key; password = nothing, host = nothing)
    isopen(s) || throw(ArgumentError("reload!: the server is closed"))
    is_tls(s) || throw(ArgumentError("reload!: the server does not serve HTTPS"))
    pw = password === nothing ? nothing : no_nul(String(password), "password")
    h = host === nothing ? "" : no_nul(String(host), "host")
    host !== nothing && isempty(h) && throw(ArgumentError("reload!: host must not be empty"))
    c, k = read_pem(cert, "certificate"), read_pem(key, "key")
    lock(RELOAD_LOCK) do
        isopen(s) || throw(ArgumentError("reload!: the server is closed"))
        tls = @ccall LIBFJL.fjl_tls_of(s.cserver::Ptr{Cvoid})::Ptr{Cvoid}
        set_cert!(tls, h, c, k, pw)
    end
    s
end

function check_tls_options(tls, opts)
    tls isa TLSConfig || throw(ArgumentError("tls must be a TLSConfig, got $(typeof(tls))"))
    opts.reactors == 1 ||
        throw(ArgumentError("HTTPS needs reactors = 1: TLS connections are not safe on several reactor threads (got reactors = $(opts.reactors))"))
    nothing
end
