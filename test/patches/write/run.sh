#!/usr/bin/env bash
# usage: run.sh <build_dir> <work_dir>
# Gather-write path and streaming (v9_write): every response shape checked
# byte by byte under a GC loop, keep-alive, pipelining, backpressure, 1,000
# mid-stream disconnects and mixed load, at 1 and 4 reactor threads and
# under TLS at 1 thread, plus a negative control (unrooted buffers) that the
# client must catch. Port 3403.
set -uo pipefail
S=$(cd "$(dirname "$0")" && pwd); T=$(cd "$S/.." && pwd)
. "$T/common.sh"
B=$1; W=$2; PORT=3403
mkdir -p "$W"
"$T/link.sh" "$B" "$S/shim.c" "$W/lib.dylib" || { result "write: link shim" 1; exit 0; }
V() { node "$S/verify.js" $PORT "$@"; }
check() { local name=$1 out r; shift; out=$(V "$@" 2>&1); r=$?; result "$name" $r "$(echo "$out" | tail -1 | cut -c1-200)"; }

# run_config <label> <threads> <tls> <quick>
run_config() {
  local L=$1 TH=$2 TLSV=$3 QUICK=$4 scheme=http s k
  [ "$TLSV" = 1 ] && scheme=https
  export TLS=$TLSV
  local base="$scheme://[::1]:$PORT"
  stats() { curl -sk --max-time 5 "$base/stats"; }
  empty() { local i; for i in $(seq 80); do s=$(stats); case "$s" in *'"live":0,"streams":0,'*'"miss":0,'*) return 0;; esac; sleep 0.25; done; return 1; }
  srv_start "$W/server_$L.log" $PORT "$base/ping" \
    env FIO_LIB="$W/lib.dylib" THREADS=$TH TLS=$TLSV GCLOOP=1 "$JULIA" -t 3 "$S/server.jl" $PORT ::1 ||
    { result "write/$L: server start" 1; return; }
  local n="write/$L"
  check "$n: shapes, every byte" shapes r,t1,t2,rslow,t1slow,t2slow
  check "$n: whole responses copy/two/gather" whole copy,two,gather
  for k in r t1 t2 rslow; do check "$n: keep-alive 5 streams $k" keepalive $k 5; done
  for k in r t1 t2; do check "$n: pipeline x3 $k" pipeline $k 3; done
  if [ "$TH" -gt 1 ]; then check "$n: pipeline x1 rslow" pipeline rslow 1; else check "$n: pipeline x3 rslow" pipeline rslow 3; fi
  empty; result "$n: buffer table empty" $? "$s"
  for k in t1 t2; do
    curl -sk -o /dev/null "$base/reset"
    check "$n: slow reader $k honours backpressure" slow $k 2000 65536 0 6
    echo "   $(stats | grep -o '"waits":[0-9]*,"max_pending":[0-9]*')"
  done
  empty; result "$n: buffer table empty after slow readers" $? "$s"
  if [ "$QUICK" = 0 ]; then
    for k in r t1 t2; do
      check "$n: 1000 mid-stream disconnects $k" disconnect $k 1000
      empty; result "$n: buffer table empty after disconnects $k" $? "$s"
      check "$n: keep-alive after disconnects $k" keepalive $k 5
    done
    check "$n: 20 s mixed streams and whole responses" load 20 24 r,t1,t2,two,gather,copy
    empty; result "$n: buffer table empty after load" $? "$s"
  fi
  check "$n: server answers at end" keepalive r 5
  srv_alive; result "$n: server alive at end" $?
  srv_stop
  grep -E 'ERROR|signal|Segmentation|Assertion' "$W/server_$L.log" | head -3
}

run_config threads1 1 0 0
run_config threads4 4 0 0
run_config tls 1 1 1
unset TLS

# Negative control: buffers lent without being kept alive must be caught.
srv_start "$W/server_noroot.log" $PORT "http://[::1]:$PORT/ping" \
  env FIO_LIB="$W/lib.dylib" NOROOT=1 GCLOOP=1 "$JULIA" -t 3 "$S/server.jl" $PORT ::1 &&
  { out=$(V load 10 24 r,t1,t2,gather 2>&1); r=$?
    result "write/noroot control: client detects corruption" "$([ $r != 0 ]; echo $?)" "$(echo "$out" | tail -1 | cut -c1-160)"
    srv_stop; } || result "write/noroot: server start" 1
exit 0
