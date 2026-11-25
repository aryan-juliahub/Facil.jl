#!/usr/bin/env bash
# usage: run.sh <build_dir> <work_dir>
# HTTP robustness: Range, static edge cases, error replies, linger, parser
# framing, header deadline, slowloris, slow readers, output flood, idle
# timeout, and a functional regression pass at 1 and 4 reactor threads.
set -uo pipefail
R=$(cd "$(dirname "$0")" && pwd)
T=$(cd "$R/.." && pwd)
. "$T/common.sh"
B=$1; W=$(mkdir -p "$2" && cd "$2" && pwd)
P=3400
LIB=$W/lib.dylib
"$T/link.sh" "$B" "$R/shim.c" "$LIB" || { result "robust: link shim" 1; exit 0; }

# Tests find their files at ../public and ../logs, so they run from a copy.
rm -rf "$W/tests" "$W/public" "$W/logs"; mkdir -p "$W/public" "$W/logs"
cp -R "$R/tests" "$W/tests"
cp "$R/a.txt" "$W/public/a.txt"
head -c 1048576 /dev/urandom > "$W/public/r_1m.bin"
LC_ALL=C tr -dc 'a-z0-9\n' < /dev/urandom | head -c 133337 > "$W/public/t_100k.txt"
trap 'srv_stop' EXIT

up() { # up [env assignments...]: starts the server with the given env
  srv_start "$W/logs/srv.log" $P "http://127.0.0.1:$P/json" \
    env PUBLIC="$W/public" "$@" "$JULIA" -t 2 "$R/server.jl" "$LIB" $P ||
    { result "robust: server start ($*)" 1; return 1; }
}
down() { srv_stop; }
# okfile <prefix> <file>: one result per "ok"/"FAIL" line of a test's output
okfile() {
  local pre=$1 f=$2 line
  while IFS= read -r line; do
    case "$line" in
      'ok   '*) result "$pre: ${line#ok   }" 0 ;;
      'FAIL '*) result "$pre: ${line#FAIL }" 1 ;;
    esac
  done < "$f"
}
alive_check() { srv_alive; result "$1: server alive" $?; }

# Range and static files
up && {
  node "$W/tests/range.mjs" $P t_100k.txt > "$W/logs/range1.txt" 2>&1
  okfile "range t_100k" "$W/logs/range1.txt"
  alive_check "range"; down; }
up && {
  node "$W/tests/range.mjs" $P r_1m.bin > "$W/logs/range2.txt" 2>&1
  n=$(grep -c '^FAIL' "$W/logs/range2.txt"); ok=$(grep -c '^ok' "$W/logs/range2.txt")
  [ "$n" = 0 ] && [ "$ok" -gt 0 ]; result "range r_1m.bin ($ok cases)" $? "$(grep '^FAIL' "$W/logs/range2.txt" | head -3 | tr '\n' ';')"
  node "$W/tests/truncate.mjs" $P > "$W/logs/truncate.txt" 2>&1
  okfile "static" "$W/logs/truncate.txt"; down; }
mkdir -p "$W/public_err"; cp "$R/public_err/"* "$W/public_err/"
srv_start "$W/logs/srv.log" $P "http://127.0.0.1:$P/json" env PUBLIC="$W/public_err" "$JULIA" -t 2 "$R/server.jl" "$LIB" $P && {
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 -X POST -d x "http://127.0.0.1:$P/a.txt")
  sleep 0.3; srv_alive && [ "$code" != 000 ]; result "POST to a static file with an error page in the folder" $? "status $code"
  down; }

# Error replies and linger (1 MiB body limit)
up MAXBODY=1 && { node "$W/tests/errors.mjs" $P > "$W/logs/errors.txt" 2>&1; okfile "errors" "$W/logs/errors.txt"; alive_check "errors"; down; }
up MAXBODY=1 && { node "$W/tests/linger.mjs" $P > "$W/logs/linger.txt" 2>&1; okfile "linger" "$W/logs/linger.txt"; down; }

# Parser framing: accepted outcomes (statuses, connection end) per case, and
# the server must answer afterwards. The strict parser rejects an oversized
# content-length or chunk size, and a bare CR ending the head, with 400.
pexp() { case $1 in
  cl-neg|cl-te|negchunk) echo 'statuses=[400] conn=closed' ;;
  cl-huge) echo 'statuses=[400] conn=closed|statuses=[413] conn=closed' ;;
  chunk-huge) echo 'statuses=[400] conn=closed' ;;
  stale-lf) echo 'statuses=[200,200,200] conn=left open|statuses=[200,400] conn=closed' ;; esac; }
for c in cl-neg cl-te cl-huge chunk-huge stale-lf negchunk; do
  up && {
    out=$(node "$W/tests/parser.mjs" $P $c 2>&1 | head -1)
    r=1; IFS='|' read -ra alts <<< "$(pexp $c)"
    for a in "${alts[@]}"; do [ "$out" = "$c: $a | server alive afterwards: true" ] && r=0; done
    result "parser $c" $r "$out"; down; }
done

# Header deadline (4 s) and slowloris: 200 dripping heads must all get 408
up HDR_TIMEOUT=4 && {
  node "$W/tests/deadline.mjs" $P 4 > "$W/logs/deadline.txt" 2>&1
  okfile "deadline" "$W/logs/deadline.txt"
  node "$W/tests/client.js" slowloris $P 200 15 > "$W/logs/slowloris.json" 2>&1
  python3 -c '
import json,sys; d=json.load(open(sys.argv[1]))
ok = d["stillOpen"] == 0 and d["closedByServer"] == 200 and d["replies"].get("HTTP/1.1 408 Request Timeout", 0) == 200
print("ok" if ok else "bad", {k: d[k] for k in ("stillOpen","closedByServer","heldSecsMax","replies")})' "$W/logs/slowloris.json" > "$W/logs/slowloris.txt" 2>&1
  grep -q '^ok' "$W/logs/slowloris.txt"; result "slowloris: 200 slow heads all closed with 408" $? "$(cut -c1-160 "$W/logs/slowloris.txt")"
  alive_check "slowloris"; down; }

# Slow readers: 200 x 8 pipelined 1 MB; then 30 clients that never read a 94 MB reply
up && {
  node "$W/tests/client.js" slowread $P 200 10 "$SRV_PID" 8 > "$W/logs/slowread.json" 2>&1
  python3 -c '
import json,sys; d=json.load(open(sys.argv[1]))
ok = d["connected"] == 200 and d["rssPeakMB"] - d["rssBeforeMB"] < 400
print("ok" if ok else "bad", {k: d[k] for k in ("connected","rssBeforeMB","rssPeakMB","droppedByServer")})' "$W/logs/slowread.json" > "$W/logs/slowread.txt" 2>&1
  grep -q '^ok' "$W/logs/slowread.txt"; result "slow readers: RSS growth under 400 MB" $? "$(cat "$W/logs/slowread.txt")"
  alive_check "slow readers"
  f0=$(lsof -p "$SRV_PID" 2>/dev/null | wc -l | tr -d ' ')
  rss0=$(ps -o rss= -p "$SRV_PID" | tr -d ' ')
  node "$W/tests/flood.mjs" $P 30 9 > /dev/null 2>&1 &
  fl=$!
  sleep 7
  f1=$(lsof -p "$SRV_PID" 2>/dev/null | wc -l | tr -d ' ')
  rss1=$(ps -o rss= -p "$SRV_PID" | tr -d ' ')
  wait $fl
  [ "$f1" -le $((f0 + 5)) ] && [ $(( (rss1 - rss0) / 1024 )) -lt 1000 ]
  result "flood: 30 never-reading clients dropped" $? "fds $f0 -> $f1, rss +$(( (rss1 - rss0) / 1024 )) MB"
  sleep 3; alive_check "flood"; down; }

# Idle timeout
up TIMEOUT=5 && { node "$W/tests/idle.mjs" $P 2000 5 > "$W/logs/idle.txt" 2>&1; okfile "idle" "$W/logs/idle.txt"; down; }

# Regression at 1 and 4 reactor threads
head -c 104857600 /dev/urandom > "$W/public/big_100m.bin"
head -c 52428800 /dev/urandom > "$W/logs/up_50m.bin"
for th in 1 4; do
  up THREADS=$th && {
    node "$W/tests/regress.mjs" $P > "$W/logs/regress$th.txt" 2>&1
    okfile "regress threads=$th" "$W/logs/regress$th.txt"
    alive_check "regress threads=$th"; down; }
done
rm -f "$W/public/big_100m.bin" "$W/logs/up_50m.bin"
exit 0
