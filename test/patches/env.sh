# Shared settings for the patch test suite. Sourced, not run.
JULIA=${JULIA:-$(julia --startup-file=no -e 'print(joinpath(Sys.BINDIR, "julia"))')}
JLIB=${JLIB:-$(dirname "$JULIA")/../lib/julia}
# Prints a prefix whose include/ has OpenSSL headers of the version Julia's libcrypto
# reports: an installed artifact, or the headers deps/build.jl downloaded.
find_openssl_prefix() {
  "$JULIA" --startup-file=no -e '
    using Libdl
    jlib, root = ARGS
    lib = first(filter(f -> occursin(r"^libcrypto(\.so\.3|\.3\.dylib|\.dylib)$", f), readdir(jlib)))
    v = ccall(dlsym(dlopen(joinpath(jlib, lib)), :OpenSSL_version_num), Culong, ())
    want = "$(v >> 28).$((v >> 20) & 0xff)"
    dirs = String[]
    for d in (joinpath(root, "deps", "build"), joinpath.(DEPOT_PATH, "artifacts")...)
        isdir(d) && append!(dirs, readdir(d; join=true))
    end
    for d in dirs
        h = joinpath(d, "include", "openssl", "opensslv.h")
        isfile(h) && isfile(joinpath(d, "include", "openssl", "ssl.h")) || continue
        s = read(h, String)
        ma = match(r"#\s*define\s+OPENSSL_VERSION_MAJOR\s+(\d+)", s)
        mi = match(r"#\s*define\s+OPENSSL_VERSION_MINOR\s+(\d+)", s)
        ma === nothing || mi === nothing || "$(ma[1]).$(mi[1])" != want || (print(d); exit(0))
    end
    exit(1)' "$JLIB" "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
}
OPENSSL=${OPENSSL:-$(find_openssl_prefix)} ||
  { echo "no OpenSSL 3 headers found: run deps/build.jl, or set OPENSSL to a prefix with include/openssl" >&2; return 1 2>/dev/null || exit 1; }
if [ "$(uname -s)" = Darwin ]; then
  ZLIB=${ZLIB:-$(xcrun --show-sdk-path)/usr/lib/libz.tbd}
  SSL_LIBS=("$JLIB/libssl.dylib" "$JLIB/libcrypto.dylib")
  SONAME_FLAGS=(-install_name @rpath/libfacil.dylib)
else
  ZLIB=${ZLIB:--lz}
  SSL_LIBS=("$JLIB/libssl.so.3" "$JLIB/libcrypto.so.3")
  SONAME_FLAGS=()
fi
AUTOCANNON=${AUTOCANNON:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/bench/scoreboard/node/node_modules/.bin/autocannon}
NODE_MODULES=${NODE_MODULES:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/bench/scoreboard/node/node_modules}
FIO_CFLAGS=(-fPIC -O2 -DNDEBUG -std=gnu11 -Wall -DHAVE_OPENSSL -DFIO_TLS_FOUND -I"$OPENSSL/include")
FIO_LDFLAGS=(-shared "${SSL_LIBS[@]}" -Wl,-rpath,"$JLIB" "$ZLIB" -lpthread -lm)
FIO_EXE_LDFLAGS=("${SSL_LIBS[@]}" -Wl,-rpath,"$JLIB" "$ZLIB" -lpthread -lm)
