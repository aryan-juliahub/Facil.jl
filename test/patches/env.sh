# Shared settings for the patch test suite. Sourced, not run.
JULIA=${JULIA:-$(julia --startup-file=no -e 'print(joinpath(Sys.BINDIR, "julia"))')}
JLIB=${JLIB:-$(dirname "$JULIA")/../lib/julia}
if [ "$(uname -s)" = Darwin ]; then
  OPENSSL=${OPENSSL:-/Users/abhimanyuaryan/web/facil-validation/v6_build/jll35/x}
  ZLIB=${ZLIB:-$(xcrun --show-sdk-path)/usr/lib/libz.tbd}
  SSL_LIBS=("$JLIB/libssl.dylib" "$JLIB/libcrypto.dylib")
  SONAME_FLAGS=(-install_name @rpath/libfacil.dylib)
else
  # OPENSSL: a prefix whose include/ has OpenSSL 3 headers (Julia ships only the libraries).
  OPENSSL=${OPENSSL:?set OPENSSL to an OpenSSL 3 prefix with include/openssl}
  ZLIB=${ZLIB:--lz}
  SSL_LIBS=("$JLIB/libssl.so.3" "$JLIB/libcrypto.so.3")
  SONAME_FLAGS=()
fi
AUTOCANNON=${AUTOCANNON:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/bench/scoreboard/node/node_modules/.bin/autocannon}
NODE_MODULES=${NODE_MODULES:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/bench/scoreboard/node/node_modules}
FIO_CFLAGS=(-fPIC -O2 -DNDEBUG -std=gnu11 -Wall -DHAVE_OPENSSL -DFIO_TLS_FOUND -I"$OPENSSL/include")
FIO_LDFLAGS=(-shared "${SSL_LIBS[@]}" -Wl,-rpath,"$JLIB" "$ZLIB" -lpthread -lm)
FIO_EXE_LDFLAGS=("${SSL_LIBS[@]}" -Wl,-rpath,"$JLIB" "$ZLIB" -lpthread -lm)
