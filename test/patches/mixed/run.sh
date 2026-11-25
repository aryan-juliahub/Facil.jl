#!/usr/bin/env bash
# usage: run.sh <build_dir> <work_dir>   Mixed load on the merged library: plain + TLS + WebSocket
# echo + uploads + no-copy downloads for MIXED_SECS (60) s at 1 reactor thread, then the same
# without TLS for MIXED4_SECS (30) s at 4 reactor threads. Ports 3413-3414.
T=$(cd "$(dirname "$0")/.." && pwd); . "$T/common.sh"
B=$1; W=$2; mkdir -p "$W"; P=3413; PT=3414
S1=${MIXED_SECS:-60}; S4=${MIXED4_SECS:-30}
export NODE_PATH=$NODE_MODULES NODE_TLS_REJECT_UNAUTHORIZED=0
INC=(); while IFS= read -r l; do INC+=("$l"); done < "$B/includes.txt"
clang -O2 -std=gnu11 -w "${INC[@]}" "$T/mixed/server.c" "$B"/obj/*.o -o "$W/server" "${FIO_EXE_LDFLAGS[@]}" ||
  { result "mixed: build" 1; exit 0; }
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$W/key.pem" -out "$W/cert.pem" -days 2 -subj /CN=localhost 2>/dev/null
trap 'srv_stop' EXIT
acsum() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["requests"]["total"], d["errors"] + d["non2xx"] + d["timeouts"])' "$1"; }

phase() { # <label> <threads> <secs> <tls 0|1>
  local label=$1 threads=$2 secs=$3 tls=$4 args=() acs=() a ok detail
  [ "$tls" = 1 ] && args=($PT "$W/cert.pem" "$W/key.pem")
  srv_start "$W/srv.$label.log" $P "http://127.0.0.1:$P/tiny" "$W/server" $P "$threads" "${args[@]}" ||
    { result "mixed $label: start" 1; return; }
  node "$T/mixed/clients.mjs" $P "$([ "$tls" = 1 ] && echo $PT || echo 0)" "$secs" > "$W/clients.$label.json" 2>"$W/clients.$label.err" &
  local cpid=$!
  "$AUTOCANNON" -c 50 -d "$secs" -j "http://127.0.0.1:$P/tiny" > "$W/ac.$label.tiny.json" 2>/dev/null & acs+=($!)
  "$AUTOCANNON" -c 8 -d "$secs" -j "http://127.0.0.1:$P/big" > "$W/ac.$label.big.json" 2>/dev/null & acs+=($!)
  [ "$tls" = 1 ] && { "$AUTOCANNON" -c 20 -d "$secs" -j "https://127.0.0.1:$PT/tiny" > "$W/ac.$label.tls.json" 2>/dev/null & acs+=($!); }
  wait "$cpid"; for a in "${acs[@]}"; do wait "$a"; done
  srv_alive; result "mixed $label: server alive after ${secs} s" $?
  read -r c < "$W/clients.$label.json"
  python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if d["errors"] == 0 and d["mismatches"] == 0 and d["ws_msgs"] > 0 and d["uploads"] > 0 and d["bigs"] > 0 else 1)' "${c:-null}"
  result "mixed $label: WebSocket echo, uploads, 1 MiB downloads verified" $? "${c:-no output: $(tail -2 "$W/clients.$label.err")}"
  for f in "$W"/ac.$label.*.json; do
    read -r n e < <(acsum "$f")
    [ "${n:-0}" -gt 0 ] && [ "$e" = 0 ]; result "mixed $label: autocannon $(basename "$f" .json | sed "s/ac.$label.//")" $? "$n requests, $e errors"
  done
  sleep 1
  local st; st=$(curl -s --max-time 5 "http://127.0.0.1:$P/stats")
  [ -n "$st" ] && [ "${st% *}" = "${st#* }" ]; result "mixed $label: every no-copy body released" $? "sent/freed $st"
  srv_alive; ok=$?
  srv_stop
  grep -qiE 'assert|fatal|segmentation|abort' "$W/srv.$label.log"; [ $? -ne 0 ] && [ $ok = 0 ]
  result "mixed $label: no crash or assertion" $?
}
phase "1-thread+tls" 1 "$S1" 1
phase "4-threads" 4 "$S4" 0
