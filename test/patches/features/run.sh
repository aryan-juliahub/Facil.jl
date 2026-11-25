#!/usr/bin/env bash
# usage: run.sh <build_dir> <work_dir>
# Feature smoke tests from the v5 spike: WebSockets, pub/sub, SSE, static
# files, uploads (temp file unlinked), hijacked streaming, timers, error
# replies, and the same through plain ccall (pure.jl). Ports 3405-3406.
set -uo pipefail
S=$(cd "$(dirname "$0")" && pwd)
T=$(cd "$S/.." && pwd)
. "$T/common.sh"
B=$1; W=$2
mkdir -p "$W"
"$T/link.sh" "$B" "$S/shim.c" "$W/lib.dylib" || { result "features: link shim" 1; exit 0; }
P=3405; U=http://127.0.0.1:$P
stat_field() { curl -s --max-time 3 "$U/stats" | tr ' ' '\n' | sed -n "s/^$1=//p"; }
tmpcount() { ls /var/tmp 2>/dev/null | grep -c '^facil_io_tmpfile_'; }

if srv_start "$W/server.log" $P "$U/hello" "$JULIA" --startup-file=no -t 4 "$S/server.jl" "$W/lib.dylib" $P 1; then
  # WebSockets and pub/sub
  node "$S/ws_client.mjs" $P > "$W/ws_client.out" 2>&1
  sed -nE 's/^(PASS|FAIL) (.*)/\1  features: ws \2/p' "$W/ws_client.out"
  grep -q 'after late send' "$W/ws_client.out" || result "features: ws client finished" 1 "$(tail -3 "$W/ws_client.out" | tr '\n' ' ')"
  closes=$(stat_field closes); opens=$(stat_field opens); dropped=$(stat_field sent_dropped)
  [ "$opens" = 3 ] && [ "$closes" = 3 ]; result "features: ws on_close once per connection" $? "opens=$opens closes=$closes"
  [ "${dropped:-0}" -ge 1 ] && srv_alive; result "features: ws send to a closed uuid is dropped" $? "sent_dropped=$dropped"

  # error replies and HEAD
  node "$S/raw_check.mjs" $P 2>&1 | grep -E '^(PASS|FAIL)  '

  # static files and sendfile
  body=$(curl -s --max-time 3 "$U/a.txt"); [ "$body" = "$(cat "$S/public/a.txt")" ]; result "features: static file" $?
  body=$(curl -s --max-time 3 "$U/"); [ "$body" = "$(cat "$S/public/index.html")" ]; result "features: static index.html" $?
  body=$(curl -s --max-time 3 "$U/sendfile"); [ "$body" = "$(cat "$S/public/a.txt")" ]; result "features: http_sendfile" $?
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$U/nope"); [ "$code" = 404 ]; result "features: 404" $? "$code"

  # upload over 8 KiB goes through a temp file that must not outlive the request
  head -c 307200 /dev/urandom > "$W/up.bin"; want=$(shasum -a 256 "$W/up.bin" | cut -d' ' -f1)
  t0=$(tmpcount)
  for i in 1 2 3 4 5; do got=$(curl -s --max-time 5 --data-binary @"$W/up.bin" "$U/upload"); done
  t1=$(tmpcount)
  [ "$got" = "len=307200 read=307200 sha256=$want" ]; result "features: 300 KB upload, sha256" $? "$got"
  [ "$t1" -le "$t0" ]; result "features: no facil_io_tmpfile left after uploads" $? "before=$t0 after=$t1"
  lsof -p "$SRV_PID" 2>/dev/null | grep -q facil_io_tmpfile_; [ $? -ne 0 ]; result "features: no temp file still open after uploads" $?

  # SSE from a Julia task
  curl -s -N --max-time 4 -H 'Accept: text/event-stream' "$U/sse" > "$W/sse.out"
  n=$(grep -c '^data: event' "$W/sse.out"); [ "$n" = 5 ]; result "features: SSE 5 events from a task, then closed" $? "events=$n"
  sleep 0.3; sc=$(stat_field sse_closes); [ "$sc" = 1 ]; result "features: SSE on_close" $? "sse_closes=$sc"

  # hijacked streaming, closed and kept open
  body=$(curl -s --max-time 4 "$U/stream"); exp=$(for i in $(seq 10); do echo "chunk $i"; done)
  [ "$body" = "$exp" ]; result "features: hijack + chunked stream from a task" $?
  body=$(curl -s --max-time 4 "$U/stream?keep"); [ "$body" = "$exp" ]; result "features: hijack stream, connection left open" $?

  # facil timer: 20 runs every 100 ms
  curl -s --max-time 3 "$U/timer?20" > /dev/null; sleep 2.6
  calls=$(stat_field timer_calls); done_=$(stat_field timer_done); span=$(stat_field timer_span)
  [ "$calls" = 20 ] && [ "$done_" = 1 ] && awk "BEGIN{exit !($span >= 1.85 && $span <= 2.3)}"
  result "features: fio_run_every 20 x 100 ms" $? "calls=$calls done=$done_ span=${span}s"

  srv_alive; result "features: server alive at the end" $?
  srv_stop
else
  result "features: server start" 1
fi

P=3406
if srv_start "$W/pure.log" $P - "$JULIA" --startup-file=no -t 4 "$S/pure.jl" "$W/lib.dylib" $P; then
  sleep 0.5
  node "$S/pure_client.mjs" $P 2>&1 | sed -nE 's/^(PASS|FAIL) (.*)/\1  features: \2/p'
  curl -s -N --max-time 3 -H 'Accept: text/event-stream' "http://127.0.0.1:$P/" > "$W/pure_sse.out"
  n=$(grep -c '^data: pure event' "$W/pure_sse.out"); [ "$n" = 3 ]; result "features: pure SSE through ccall" $? "events=$n"
  srv_alive; result "features: pure server alive at the end" $?
  srv_stop
else
  result "features: pure server start" 1
fi
exit 0
