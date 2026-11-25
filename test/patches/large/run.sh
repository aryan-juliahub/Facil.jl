#!/usr/bin/env bash
# usage: run.sh <build_dir> <work_dir>
# No-copy large bodies (v7_large): byte-exact sizes, keep-alive, pipelining,
# HEAD, connection close, load under a GC loop and 1,000 mid-download
# disconnects, for both no-copy modes (C: two packets, D: gather). Port 3402.
set -uo pipefail
S=$(cd "$(dirname "$0")" && pwd); T=$(cd "$S/.." && pwd)
. "$T/common.sh"
B=$1; W=$2; PORT=3402; BASE=http://127.0.0.1:$PORT
mkdir -p "$W"
"$T/link.sh" "$B" "$S/shim.c" "$W/lib.dylib" -DPATCHED || { result "large: link shim" 1; exit 0; }
V() { node "$S/verify.js" $PORT "$@"; }
sha() { shasum -a 256 | cut -c1-16; }
empty() { local s i; for i in $(seq 40); do s=$(curl -s --max-time 5 $BASE/stats); case "$s" in *'"live":0,'*'"miss":0,'*) echo "$s"; return 0;; esac; sleep 0.25; done; echo "$s"; return 1; }

for VAR in C D; do
  n="large/$VAR"
  srv_start "$W/server_$VAR.log" $PORT $BASE/stats \
    env FIO_LIB=$W/lib.dylib GCLOOP=1 "$JULIA" -t 2 "$S/server.jl" $VAR $PORT || { result "$n: server start" 1; continue; }
  bad=""
  for sz in 1024 8192 32768 102400 1048576 10485760; do
    [ "$(V pattern $sz | sha)" = "$(curl -s --max-time 20 $BASE/s/$sz | sha)" ] || bad="$bad $sz"
  done
  result "$n: bodies byte-exact 1 KB..10 MB" "$([ -z "$bad" ]; echo $?)" "${bad:+bad sizes:$bad}"
  args=(); for sz in 1024 102400 8192 1048576 32768 102400; do args+=("$BASE/s/$sz" -o "$W/ka.${#args[@]}"); done
  curl -sv --max-time 30 "${args[@]}" 2> "$W/ka.err"
  conns=$(grep -c 'Connected to' "$W/ka.err"); okc=0; i=0
  for sz in 1024 102400 8192 1048576 32768 102400; do
    [ "$(V pattern $sz | sha)" = "$(sha < "$W/ka.$((i*3))")" ] && okc=$((okc+1)); i=$((i+1))
  done
  result "$n: keep-alive 6 bodies on one connection" "$([ $okc = 6 ] && [ $conns = 1 ]; echo $?)" "$okc/6 ok, $conns conns"
  out=$(V pipeline); result "$n: pipelined 6 responses in order" $? "$(echo "$out" | tail -1)"
  out=$(V head 102400); result "$n: HEAD no body, next GET intact" $? "$(echo "$out" | tail -1 | cut -c1-120)"
  for opt in "-H connection:close" "--http1.0"; do
    got=$(curl -s --max-time 10 $opt -o "$W/close.bin" -w '%{http_code} %{size_download}' $BASE/s/102400)
    [ "$(V pattern 102400 | sha)" = "$(sha < "$W/close.bin")" ] && [ "$got" = "200 102400" ]
    result "$n: curl $opt" $? "$got"
  done
  s=$(empty); result "$n: buffer table empty after basics" $? "$s"
  out=$(V load 20 32 1024,32768,102400,1048576 fresh); result "$n: 20 s fresh Vector bodies, GC loop" $? "$out"
  out=$(V load 8 32 1024,102400,1048576 freshstr); result "$n: 8 s fresh String bodies, GC loop" $? "$out"
  out=$(V disconnect 1000 10485760); r=$?
  s=$(empty); result "$n: 1000 mid-download disconnects, table empty" "$([ $r = 0 ] && [[ "$s" == *'"live":0,'*'"miss":0,'* ]]; echo $?)" "$s"
  srv_alive; result "$n: server alive at end" $?
  srv_stop
  grep -iE 'error|signal|segfault|abort' "$W/server_$VAR.log" | head -3
done
exit 0
