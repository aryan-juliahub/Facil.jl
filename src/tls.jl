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

Certificates and settings for an HTTPS server, given to [`serve!`](@ref) as `tls`.

`cert` and `key` are file paths or PEM text. `cert` may hold the whole chain,
leaf first. `password` unlocks an encrypted key. Files are read when the
`TLSConfig` is built, and each certificate is checked against its key, so a
missing file, a wrong password or a mismatched pair throws here.

- `sni`: extra certificates chosen by the name the client asks for, as
  `(host, cert, key)` or `(host, cert, key, password)` tuples (the first form
  uses `password`). `host` may be a wildcard such as `"*.example.com"`. Other
  names get the default `cert`.
- `min_version`, `max_version`: protocol range, `v"1.2"` or `v"1.3"`. TLS 1.0 and
  1.1 also need `ciphers = "DEFAULT@SECLEVEL=0"` with OpenSSL 3.
- `ciphers`: OpenSSL cipher list for TLS 1.2; `ciphersuites`: TLS 1.3 suites.
- `prefer_server_ciphers`: the server's cipher order wins over the client's.
- `client_ca`: CA certificates (path or PEM) that client certificates are
  verified against. A client presenting another certificate is refused;
  with `require_client_cert = true` a client presenting none is refused too.

HTTPS servers need `reactors = 1`.
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
    TLSError

A certificate, key or setting that OpenSSL refused.
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
    reload!(server, cert, key; password = nothing, host = nothing)
    reload!(server; cert, key, password = nothing, host = nothing)

Replaces the certificate of an HTTPS server while it runs: connections made
from now on get the new one, open connections keep theirs. `host` picks an
`sni` entry (a new host adds one); `nothing` replaces the default certificate.
`cert` and `key` are paths or PEM text. A bad pair throws and changes nothing.
"""
reload!(s::Server; cert, key, password = nothing, host = nothing) = reload!(s, cert, key; password, host)

function reload!(@nospecialize(s::Server), cert, key; password = nothing, host = nothing)
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
