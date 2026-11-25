#!/usr/bin/env bash
# usage: run.sh <build_dir> <work_dir>   TLS safety and configuration checks (ports 3410, 3411).
# TLS runs with one reactor thread. Ported from the v10_tls spike (safety.sh, cfg_test.sh).
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd); T=$(cd "$D/.." && pwd)
. "$T/common.sh"
B=$1; W=$2; mkdir -p "$W"
PORT=3410; CPORT=3411
LIB=$W/libtls.dylib
"$T/link.sh" "$B" "$D/shim.c" "$LIB" || { result "tls: link shim" 1; exit 0; }
for t in tls_probe tlsload; do
  clang -O2 -w -I"$OPENSSL/include" "$D/$t.c" -o "$W/$t" "${SSL_LIBS[@]}" -Wl,-rpath,"$JLIB" -lpthread ||
    { result "tls: build $t" 1; exit 0; }
done
python3 - "$W" <<'PY'
import sys
for n, f in ((102400, "b100k"), (1048576, "b1m"), (52428800, "b50m")):
    open(f"{sys.argv[1]}/{f}", "wb").write(bytes(((i * 7 + (i >> 10)) & 0xff) for i in range(n)))
PY
trap 'srv_stop' EXIT

# name | key | cert | server env | mode
while IFS='|' read -r -u 3 NAME key cert envs MODE; do
  srv_start "$W/$NAME.log" $PORT https://127.0.0.1:$PORT/json env FIO_THREADS=1 $envs \
    "$JULIA" --startup-file=no -t 3 "$D/server.jl" "$LIB" $PORT "$D/$cert" "$D/$key" ||
    { result "$NAME: server starts" 1; continue; }
  . "$D/safety.sh"
  srv_stop
done 3<<'EOF2'
copy|key.pem|cert.pem|RESP=A|
nocopy-2pkt-gc|key.pem|cert.pem|RESP=C GCLOOP=1|gc
nocopy-gather|key.pem|cert.pem|RESP=D|
copy-ec|certs/ec_key.pem|certs/ec_cert.pem|RESP=A|
EOF2

. "$D/cfg.sh"
exit 0
