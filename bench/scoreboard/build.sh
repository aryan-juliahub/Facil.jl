#!/usr/bin/env bash
# Builds the load clients into bin/, installs the pinned Node packages, writes data/ (payloads, certs).
#   bench/scoreboard/build.sh            OPENSSL_PREFIX overrides where tlsload finds OpenSSL
set -euo pipefail
S=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$S/bin" "$S/data"
CC=${CC:-clang}
"$CC" -O2 -Wall -o "$S/bin/lat" "$S/clients/lat.c"
"$CC" -O2 -Wall -o "$S/bin/wsbench" "$S/clients/wsbench.c" -lpthread
OSSL=${OPENSSL_PREFIX:-}
if [ -z "$OSSL" ]; then
  for d in /opt/homebrew/opt/openssl@3 /opt/homebrew/opt/openssl /usr/local/opt/openssl@3 /usr/local/opt/openssl; do
    [ -f "$d/include/openssl/ssl.h" ] && { OSSL=$d; break; }
  done
fi
if [ -n "$OSSL" ] && [ -f "$OSSL/include/openssl/ssl.h" ]; then
  "$CC" -O2 -Wall -I"$OSSL/include" -o "$S/bin/tlsload" "$S/clients/tlsload.c" -L"$OSSL/lib" -lssl -lcrypto -lpthread
else
  echo "build.sh: no OpenSSL headers (set OPENSSL_PREFIX); TLS rows will report 'client not built'" >&2
fi
if [ ! -d "$S/node/node_modules/uWebSockets.js" ] || [ ! -x "$S/node/node_modules/.bin/autocannon" ]; then
  (cd "$S/node" && npm ci --no-audit --no-fund)
fi
node "$S/node/gen_data.js" "$S/data"
if [ ! -f "$S/data/rsa_cert.pem" ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=localhost \
    -keyout "$S/data/rsa_key.pem" -out "$S/data/rsa_cert.pem" 2>/dev/null
  openssl ecparam -name prime256v1 -genkey -noout -out "$S/data/ec_key.pem"
  openssl req -x509 -new -key "$S/data/ec_key.pem" -days 3650 -subj /CN=localhost -out "$S/data/ec_cert.pem" 2>/dev/null
fi
echo "built: $(ls "$S/bin" | tr '\n' ' ')"
