# usage: julia cfg_server.jl <lib> <port>      TLS configuration proofs, driven by environment:
#   CFG_CERTS="name|cert file|key file|password;..."   first entry goes through fio_tls_new, the rest through fio_tls_cert_add
#   CFG_PEM=1        pass the same entries as PEM strings through fio_tls_cert_set_pem instead (patched library)
#   CFG_MIN=1.3  CFG_CIPHERS=...  CFG_SUITES=...  CFG_FLAGS=<FIO_TLS_* bits>     -> fio_tls_configure (patched library)
#   CFG_TRUST=<ca file>     -> fio_tls_trust
#   CFG_TICKETS=<n>         -> fio_tls_on_context + SSL_CTX_ctrl(SSL_CTRL_SET_NUM_TICKETS) called from Julia
# GET /reload swaps "localhost" to certs/renewed_*.pem while the listener keeps running.
using Libdl
struct HttpSettings
    on_request::Ptr{Cvoid}; on_upgrade::Ptr{Cvoid}; on_response::Ptr{Cvoid}; on_finish::Ptr{Cvoid}
    udata::Ptr{Cvoid}; public_folder::Ptr{Cchar}; public_folder_length::Csize_t
    max_header_size::Csize_t; max_body_size::Csize_t; max_clients::Int; tls::Ptr{Cvoid}
    reserved1::Int; reserved2::Int; reserved3::Int; ws_max_msg_size::Csize_t
    timeout::UInt8; ws_timeout::UInt8; log::UInt8; is_client::UInt8
end
struct FioStartArgs; threads::Int16; workers::Int16; end
struct Slice; ptr::Ptr{UInt8}; len::Csize_t; end
const lib = ARGS[1]
const HERE = @__DIR__
const TLS = Ref{Ptr{Cvoid}}(C_NULL)
const RELOADS = Ref(0)
const LIBSSL = joinpath(Sys.BINDIR, "..", "lib", "julia", Sys.isapple() ? "libssl.3.dylib" : "libssl.so.3")

set_pem(name, cert, key, pw) = ccall((:fio_tls_cert_set_pem, lib), Cint,
    (Ptr{Cvoid}, Cstring, Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t, Cstring),
    TLS[], name, cert, sizeof(cert), key, sizeof(key), isempty(pw) ? C_NULL : pw)

function on_request(h::Ptr{Cvoid})::Cvoid
    p = Ref(Slice(C_NULL, 0)); q = Ref(Slice(C_NULL, 0))
    ccall((:shim_path, lib), Cvoid, (Ptr{Cvoid}, Ref{Slice}, Ref{Slice}), h, p, q)
    path = unsafe_string(p[].ptr, p[].len)
    body = "ok" * " "^200 * "\n"
    if path == "/reload"
        r = set_pem("localhost", read(joinpath(HERE, "certs", "renewed_cert.pem")), read(joinpath(HERE, "certs", "renewed_key.pem")), "")
        RELOADS[] += 1
        body = "reload $(RELOADS[]) -> $r\n"
    elseif path == "/reload-bad"
        r = set_pem("localhost", read(joinpath(HERE, "certs", "renewed_cert.pem")), read(joinpath(HERE, "certs", "a_key.pem")), "")
        body = "reload with a mismatched key -> $r\n"
    end
    ccall((:http_send_body, lib), Cint, (Ptr{Cvoid}, Ptr{UInt8}, Csize_t), h, body, sizeof(body))
    return nothing
end

# Receives each SSL_CTX facil.io builds; anything OpenSSL offers can be set from here.
function on_ctx(ctx::Ptr{Cvoid}, udata::Ptr{Cvoid})::Cvoid
    n = parse(Int, ENV["CFG_TICKETS"])
    ccall((:SSL_CTX_set_num_tickets, LIBSSL), Cint, (Ptr{Cvoid}, Csize_t), ctx, n)
    return nothing
end

function main()
    entries = [split(e, '|') for e in split(get(ENV, "CFG_CERTS", "localhost|$HERE/cert.pem|$HERE/key.pem|"), ';')]
    pem = get(ENV, "CFG_PEM", "0") == "1"
    if pem
        TLS[] = ccall((:fio_tls_new, lib), Ptr{Cvoid}, (Ptr{Cchar}, Ptr{Cchar}, Ptr{Cchar}, Ptr{Cchar}), C_NULL, C_NULL, C_NULL, C_NULL)
        for (name, cert, key, pw) in entries
            r = set_pem(String(name), read(String(cert)), read(String(key)), String(pw))
            println("fio_tls_cert_set_pem($name) -> $r")
        end
    else
        for (i, (name, cert, key, pw)) in enumerate(entries)
            if i == 1
                TLS[] = ccall((:fio_tls_new, lib), Ptr{Cvoid}, (Cstring, Cstring, Cstring, Cstring), String(name), String(cert), String(key), isempty(pw) ? C_NULL : String(pw))
            else
                ccall((:fio_tls_cert_add, lib), Cvoid, (Ptr{Cvoid}, Cstring, Cstring, Cstring, Cstring), TLS[], String(name), String(cert), String(key), isempty(pw) ? C_NULL : String(pw))
            end
        end
    end
    haskey(ENV, "CFG_TRUST") && ccall((:fio_tls_trust, lib), Cvoid, (Ptr{Cvoid}, Cstring), TLS[], ENV["CFG_TRUST"])
    if any(k -> haskey(ENV, k), ("CFG_MIN", "CFG_CIPHERS", "CFG_SUITES", "CFG_FLAGS"))
        vers = Dict("1.2" => 0x0303, "1.3" => 0x0304)
        r = ccall((:fio_tls_configure, lib), Cint, (Ptr{Cvoid}, Cint, Cint, Cstring, Cstring, Cint), TLS[],
                  get(vers, get(ENV, "CFG_MIN", ""), 0), 0,
                  haskey(ENV, "CFG_CIPHERS") ? ENV["CFG_CIPHERS"] : C_NULL,
                  haskey(ENV, "CFG_SUITES") ? ENV["CFG_SUITES"] : C_NULL,
                  parse(Cint, get(ENV, "CFG_FLAGS", "0")))
        println("fio_tls_configure -> $r")
    end
    if haskey(ENV, "CFG_BAD_SUITES")
        r = ccall((:fio_tls_configure, lib), Cint, (Ptr{Cvoid}, Cint, Cint, Cstring, Cstring, Cint), TLS[], 0, 0, C_NULL, ENV["CFG_BAD_SUITES"], 0)
        println("fio_tls_configure with an unknown ciphersuite -> $r (the previous settings stay)")
    end
    if haskey(ENV, "CFG_TICKETS")
        r = ccall((:fio_tls_on_context, lib), Cint, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}), TLS[], @cfunction(on_ctx, Cvoid, (Ptr{Cvoid}, Ptr{Cvoid})), C_NULL)
        println("fio_tls_on_context -> $r")
    end
    s = HttpSettings(@cfunction(on_request, Cvoid, (Ptr{Cvoid},)), C_NULL, C_NULL, C_NULL, C_NULL, C_NULL, 0, 0, 0, 0, TLS[], 0, 0, 0, 0, 0, 0, 0, 0)
    ccall((:http_listen, lib), Int, (Cstring, Cstring, HttpSettings), ARGS[2], "127.0.0.1", s) < 0 && error("http_listen failed")
    flush(stdout)
    wait(Threads.@spawn @ccall gc_safe=true lib.fio_start(FioStartArgs(1, 1)::FioStartArgs)::Cvoid)
end
main()
