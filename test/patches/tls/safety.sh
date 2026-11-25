# Byte-exactness and robustness checks over TLS against the server started last
# (SRV_PID on port $PORT). Sourced by run.sh with: NAME, PORT, W, MODE ("" or gc).
U=https://127.0.0.1:$PORT
S=$W/safety.$NAME; mkdir -p "$S"
say() { result "$NAME: $2" "$1" "${3:-}"; }
sha() { shasum -a 256 | cut -d' ' -f1; }
want() { shasum -a 256 "$W/$1" | cut -d' ' -f1; }
rss() { ps -o rss= -p "$SRV_PID" | tr -d ' '; }
S100=$(want b100k); S1M=$(want b1m); S50=$(want b50m)

for spec in "102400 $S100" "1048576 $S1M" "52428800 $S50"; do set -- $spec
  [ "$(curl -sk --max-time 60 $U/s/$1 | sha)" = "$2" ]; say $? "download $1 bytes sha256"
done
[ "$(curl -sk --max-time 60 -H 'Connection: close' $U/s/1048576 | sha)" = "$S1M" ]; say $? "download 1 MB with Connection: close"
[ "$(curl -sk --max-time 60 --limit-rate 20M $U/s/52428800 | sha)" = "$S50" ]; say $? "download 50 MB by a slow reader (20 MB/s)"
r=$(curl -sk --max-time 60 -H 'Expect:' --data-binary @"$W/b50m" $U/upload)
[ "$r" = "len=52428800 read=52428800 sha256=$S50" ]; say $? "upload 50 MB sha256"
r=$("$W/tls_probe" bigrec "$PORT" 16000 2>/dev/null)
echo "$r" | grep -q "len=16000 read=16000 sha256=34c06ff759aaf7ff"; say $? "POST with head and 16 KB body in one TLS record" "$(echo "$r" | cut -c1-40)"

n=$(curl -sk --max-time 20 -o /dev/null -o /dev/null -o /dev/null -o /dev/null -o /dev/null -w '%{num_connects}\n' $U/json $U/s/102400 $U/json $U/s/1048576 $U/json | awk '{s += $1} END {print s}')
[ "$n" = 1 ]; say $? "keep-alive x5 on one connection" "connects: $n"
r=$("$W/tls_probe" coalesce "$PORT" 3 2>/dev/null); echo "$r" | grep -q OK; say $? "pipelining x3 in the handshake's last segment"
r=$("$W/tls_probe" coalesce "$PORT" 12 2>/dev/null); echo "$r" | grep -q OK; say $? "pipelining x12 in the handshake's last segment"

pids=""; for i in $(seq 16); do (curl -sk --max-time 60 $U/s/1048576 | sha > "$S/par.$i") & pids="$pids $!"; done; wait $pids
bad=0; for i in $(seq 16); do [ "$(cat "$S/par.$i")" = "$S1M" ] || bad=$((bad + 1)); done
[ $bad = 0 ]; say $? "16 concurrent 1 MB downloads" "mismatches: $bad"

[ "$(curl -sk --max-time 30 --tls-max 1.2 -w '%{http_code}' -o "$S/t12" $U/s/1048576)" = 200 ] && [ "$(sha < "$S/t12")" = "$S1M" ]; say $? "TLS 1.2 client, 1 MB sha256"
curl -skv --max-time 30 -o "$S/t13" $U/s/1048576 2> "$S/t13.log"
grep -q 'SSL connection using TLSv1.3' "$S/t13.log" && [ "$(sha < "$S/t13")" = "$S1M" ]; say $? "TLS 1.3 client, 1 MB sha256"

curl -sk -o /dev/null $U/s/1048576; r0=$(rss)
r=$("$W/tls_probe" abort "$PORT" 1000 1048576 2>/dev/null); sleep 1; r1=$(rss)
"$W/tls_probe" abort "$PORT" 1000 1048576 > /dev/null 2>&1; sleep 1; r2=$(rss)
alive=1; srv_alive && [ "$(curl -sk --max-time 10 $U/s/1048576 | sha)" = "$S1M" ] && alive=0
st=$(curl -sk --max-time 5 $U/stats)
[ $alive = 0 ] && echo "$r" | grep -q "1000 of 1000" && [ $((r2 - r1)) -lt 20000 ]; say $? "client aborts mid-download x1000, twice" "RSS kB $r0 / $r1 / $r2; $st"

if [ "$MODE" = gc ]; then
  ( "$W/tlsload" ka "$PORT" /fresh/102400 32 2 0 30 > "$S/gc.load" ) & lp=$!
  bad=0; n=0
  while kill -0 $lp 2>/dev/null; do [ "$(curl -sk --max-time 20 $U/fresh/102400 | sha)" = "$S100" ] || bad=$((bad + 1)); n=$((n + 1)); done
  wait $lp; sleep 1
  st=$(curl -sk --max-time 5 $U/stats)
  srv_alive && [ $bad = 0 ] && grep -q '"errors":0' "$S/gc.load" && echo "$st" | grep -q '"roots":0'; say $? "30 s of no-copy sends under a GC.gc() loop" "$n bodies, $bad wrong; $(grep -o '"count":[0-9]*,"rate":[0-9]*,"errors":[0-9]*' "$S/gc.load"); $st"
fi
c0=$(ps -o time= -p "$SRV_PID" | tr -d ' '); r=$("$W/tls_probe" stall "$PORT" 14); c1=$(ps -o time= -p "$SRV_PID" | tr -d ' ')
cpu() { echo "$1" | awk -F: '{ s = 0; for (i = 1; i <= NF; i++) s = s * 60 + $i; print s }'; }
# a GC.gc() loop burns CPU of its own, so the spin check is skipped there
spin=$(awk "BEGIN { print ($(cpu "$c1") - $(cpu "$c0") < 2) ? 0 : 1 }"); [ "$MODE" = gc ] && spin=0
echo "$r" | grep -q "server closed" && [ "$spin" = 0 ]; say $? "silent TCP connection is closed without spinning" "$r; CPU $c0 -> $c1"
srv_alive; say $? "server still running"
