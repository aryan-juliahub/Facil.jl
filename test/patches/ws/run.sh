#!/usr/bin/env bash
# usage: run.sh <build_dir> <work_dir>
# WebSocket checks from the v10_ws spike: protocol (verify.mjs) at 1 and 4
# reactor threads, permessage-deflate, ping timeouts, subscriber churn,
# broadcast order at 4 threads, slow-subscriber policies. Ports 3407-3409.
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd)
T=$(cd "$D/.." && pwd)
. "$T/common.sh"
B=$1; W=$2
mkdir -p "$W"
export NODE_PATH=$NODE_MODULES
P=3407
LIB=$W/libws.dylib
"$T/link.sh" "$B" "$D/shim.c" "$LIB" -DWS_PATCHED=1 || { result "ws: link fixture" 1; exit 0; }
clang -O2 -w "$D/wsbench.c" -o "$W/wsbench" -lpthread || { result "ws: build wsbench" 1; exit 0; }
trap srv_stop EXIT

up() { # up <tag> [ENV=val ...]
  local tag=$1; shift
  srv_start "$W/srv.$tag.log" $P "http://127.0.0.1:$P/stats" \
    env WS_MAX_MSG=8388608 "$@" "$JULIA" --startup-file=no -t 3 "$D/server.jl" "$LIB" $P ||
    { result "ws $tag: server start" 1; return 1; }
}
# Re-prints a node script's "PASS x" / "FAIL x" lines in the suite format.
relay() { sed -nE "s/^(PASS|FAIL) (.*)$/\1  $1: \2/p"; }
alive_check() { srv_alive; result "ws $1: server alive afterwards" $?; }
json_field() { sed -nE "s/.*\"$1\":([0-9]+).*/\1/p" "$2" | head -1; }

verify() { # verify <tag> [ENV=val ...]
  local tag=$1; shift
  up "$tag" "$@" || return
  node "$D/verify.mjs" $P > "$W/verify.$tag.txt" 2>&1
  relay "ws $tag" < "$W/verify.$tag.txt"
  grep -q '^SUMMARY' "$W/verify.$tag.txt" || result "ws $tag: verify.mjs finished" 1 "$(tail -1 "$W/verify.$tag.txt")"
  alive_check "$tag"; srv_stop
}
verify t1
verify t4 FIO_THREADS=4

if up deflate WS_DEFLATE=1; then
  node "$D/verify.mjs" $P deflate > "$W/verify.deflate.txt" 2>&1; relay "ws deflate-client" < "$W/verify.deflate.txt"
  node "$D/deflate_check.mjs" $P > "$W/deflate_check.txt" 2>&1; relay "ws deflate" < "$W/deflate_check.txt"
  grep -q '^SUMMARY' "$W/deflate_check.txt" || result "ws deflate: deflate_check.mjs finished" 1
  alive_check deflate; srv_stop
fi

if up timeout WS_TIMEOUT=2; then
  node "$D/timeout_check.mjs" $P > "$W/timeout.txt" 2>&1
  grep -q 'answering client (ws): [1-9][0-9]* pings in 9 s, still open' "$W/timeout.txt"
  result "ws timeout: answering client is pinged and kept" $? "$(head -1 "$W/timeout.txt")"
  grep -q 'silent client (raw, never pongs): [0-9]* pings, dropped after' "$W/timeout.txt"
  result "ws timeout: silent client is dropped" $? "$(sed -n 2p "$W/timeout.txt")"
  srv_stop
fi

probe() { "$W/wsbench" echo $P /echo 1 1 64 text 0 0.2 2>/dev/null | grep -q '"connect_errors":0.*"errors":0'; }

# 1,000 subscribers reset mid-broadcast, five rounds; every open must be closed.
churn() { # churn <tag> [ENV=val ...]
  local tag=$1 round cp i; shift
  up "churn-$tag" "$@" || return
  curl -s "http://127.0.0.1:$P/start?n=20&rate=1000&size=200" > /dev/null; sleep 1
  for round in 1 2 3 4 5; do
    rm -f "$W/churn.ready"
    "$W/wsbench" sub $P /sub 1000 2 1000000 30 "$W/churn.ready" > /dev/null 2>&1 & cp=$!
    for i in $(seq 200); do [ -f "$W/churn.ready" ] && break; sleep 0.1; done
    curl -s "http://127.0.0.1:$P/start?n=6000&rate=1000&size=200" > /dev/null
    sleep 2.5; kill -9 $cp 2>/dev/null; wait $cp 2>/dev/null
    sleep 3
  done
  srv_alive && probe; result "ws churn $tag: server alive and echoing after 5 rounds" $?
  local st; st=$(curl -s --max-time 3 "http://127.0.0.1:$P/stats")
  local o c; o=$(sed -nE 's/.*"opens":([0-9]+).*/\1/p' <<< "$st"); c=$(sed -nE 's/.*"closes":([0-9]+).*/\1/p' <<< "$st")
  [ -n "$o" ] && [ "$o" = "$c" ] && [ "$o" -ge 5000 ]; result "ws churn $tag: every open closed" $? "opens=$o closes=$c"
  srv_stop
}
churn t1
churn t4 FIO_THREADS=4

# bcast <tag> <subs> <rate> <secs> <stalled> [ENV=val ...]: one broadcast run;
# leaves the client result in $W/bc.<tag>.json and the server stats in .stats.
bcast() {
  local tag=$1 subs=$2 rate=$3 secs=$4 stalled=$5 cp i; shift 5
  local raw=$W/bc.$tag.json
  up "bc-$tag" "$@" || return 1
  probe || { result "ws bcast $tag: echo probe" 1; srv_stop; return 1; }
  curl -s --max-time 5 "http://127.0.0.1:$P/start?n=20&rate=1000&size=200" > /dev/null; sleep 1
  rm -f "$raw.ready"
  "$W/wsbench" sub $P /sub "$subs" 3 $((rate * secs)) $((secs + 30)) "$raw.ready" "$stalled" > "$raw" 2> "$raw.err" & cp=$!
  for i in $(seq 600); do [ -f "$raw.ready" ] && break; sleep 0.1; done
  sleep 1
  curl -s --max-time 5 "http://127.0.0.1:$P/start?n=$((rate * secs))&rate=$rate&size=${BC_SIZE:-200}" > /dev/null
  wait $cp
  curl -s --max-time 5 "http://127.0.0.1:$P/stats" > "$raw.stats"
  srv_alive; result "ws bcast $tag: server alive afterwards" $?
  srv_stop
}
bc_exact() { # every non-stalled subscriber got every message, in order
  local raw=$W/bc.$1.json m e er ce
  m=$(json_field msgs "$raw"); e=$(json_field expected "$raw"); er=$(json_field errors "$raw"); ce=$(json_field connect_errors "$raw")
  [ -n "$m" ] && [ "$m" = "$e" ] && [ "$er" = 0 ] && [ "$ce" = 0 ]
  result "ws bcast $1: exact count, per-subscriber order" $? "msgs=$m expected=$e errors=$er connect_errors=$ce"
}

bcast order4 1000 1000 5 0 FIO_THREADS=4 && bc_exact order4

# Linux grows a stalled loopback connection's send buffer to 4 MiB, so there
# the backlog must exceed that before the 1 MiB server-side limit is reached.
if [ "$(uname -s)" = Linux ]; then export BC_SIZE=5000; else export BC_SIZE=1000; fi
L=WS_SLOW_LIMIT=1048576
if bcast slow-close 1000 200 10 100 $L WS_SLOW_POLICY=close; then
  bc_exact slow-close
  n=$(json_field slow_closed "$W/bc.slow-close.json.stats")
  [ "$n" = 100 ]; result "ws slow close: the 100 stalled subscribers are closed" $? "slow_closed=$n"
fi
for pol in oldest newest; do
  if bcast slow-$pol 1000 200 10 100 $L WS_SLOW_POLICY=$pol; then
    bc_exact slow-$pol
    n=$(json_field slow_dropped "$W/bc.slow-$pol.json.stats"); c=$(json_field slow_closed "$W/bc.slow-$pol.json.stats")
    [ "${n:-0}" -gt 0 ] && [ "$c" = 0 ]; result "ws slow drop-$pol: messages dropped, nobody closed" $? "slow_dropped=$n slow_closed=$c"
  fi
done
if bcast slow-none 1000 200 10 100; then
  bc_exact slow-none
fi
unset BC_SIZE
exit 0
