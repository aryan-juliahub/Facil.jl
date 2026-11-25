#!/usr/bin/env bash
# usage: run.sh <build_dir> <work_dir>   Throughput spot-check of /tiny (v3_speed server, variant b,
# 1 reactor thread) against stock facil.io built the same way. Run on a quiet machine.
# STOCK_BUILD=<dir> reuses a stock build; otherwise stock 51287473 is built into <work_dir>.
T=$(cd "$(dirname "$0")/.." && pwd); . "$T/common.sh"
B=$1; W=$2; mkdir -p "$W"; PORT=3412
SB=${STOCK_BUILD:-$W/stock_build}
if [ ! -f "$SB/libfacil.dylib" ]; then
  rm -rf "$W/stock_src"; mkdir -p "$W/stock_src"; cp -R "$T/../../deps/facil.io/lib" "$W/stock_src/lib"
  "$T/build.sh" "$W/stock_src" "$SB" || { result "spot: stock build" 1; exit 0; }
fi
"$T/link.sh" "$B" "$T/spot/shim.c" "$W/lib.dylib" && "$T/link.sh" "$SB" "$T/spot/shim.c" "$W/lib_stock.dylib" ||
  { result "spot: link" 1; exit 0; }
trap 'srv_stop' EXIT
shot() { # <lib> <label> <autocannon args...> -> req/s
  local lib=$1 label=$2; shift 2
  FACIL_LIB=$lib srv_start "$W/srv.$label.log" $PORT "http://127.0.0.1:$PORT/tiny" "$JULIA" "$T/spot/facil_server.jl" b $PORT || return 1
  "$AUTOCANNON" -c 100 -d 2 "http://127.0.0.1:$PORT/tiny" > /dev/null 2>&1
  "$AUTOCANNON" "$@" -d 5 -j "http://127.0.0.1:$PORT/tiny" > "$W/ac.$label.json" 2>/dev/null
  srv_stop
  python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(int(d["requests"]["average"]), d["errors"] + d["non2xx"] + d["timeouts"])' "$W/ac.$label.json"
}
for shape in "c100" "c100w4"; do
  args=(-c 100); [ $shape = c100w4 ] && args=(-c 100 -w 4)
  read -r m1 e1 < <(shot "$W/lib.dylib" "merged.$shape.1" "${args[@]}")
  read -r s1 e2 < <(shot "$W/lib_stock.dylib" "stock.$shape.1" "${args[@]}")
  read -r m2 e3 < <(shot "$W/lib.dylib" "merged.$shape.2" "${args[@]}")
  read -r s2 e4 < <(shot "$W/lib_stock.dylib" "stock.$shape.2" "${args[@]}")
  m=$(( m1 > m2 ? m1 : m2 )); s=$(( s1 > s2 ? s1 : s2 )); errs=$((e1 + e2 + e3 + e4))
  awk -v m="$m" -v s="$s" -v e="$errs" 'BEGIN { exit !(s > 0 && m / s >= 0.9 && e == 0) }'
  result "spot: /tiny $shape, merged vs stock" $? "merged $m req/s, stock $s req/s, ratio $(awk -v m="$m" -v s="$s" 'BEGIN { printf "%.3f", (s ? m / s : 0) }'), errors $errs"
done
