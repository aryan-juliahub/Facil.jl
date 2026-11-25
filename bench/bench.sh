#!/usr/bin/env bash
# Usage: [PORT=3430] [URLPATH=/] [DURATION=10] [CONNS=100] [WORKERS=4] [RUNS=1] \
#        bench/bench.sh <name> <server command...>
# Starts the server, refuses to run unless that exact process owns $PORT, prints
# one response, warms up, then runs autocannon RUNS times. The server command
# sees PORT in its environment. Results go to $OUT/<name>.<run>.json.
#   AC   autocannon binary (default: autocannon on PATH, else `npx autocannon`)
#   OUT  results directory (default: ${TMPDIR:-/tmp}/facil-bench)
# Example: bench/bench.sh const julia --project=. test/core.jl serve 3430
set -u
PORT=${PORT:-3430}
URLPATH=${URLPATH:-/}
DURATION=${DURATION:-10}
CONNS=${CONNS:-100}
WORKERS=${WORKERS:-4}
RUNS=${RUNS:-1}
OUT=${OUT:-${TMPDIR:-/tmp}/facil-bench}
if [ -z "${AC:-}" ]; then
  if command -v autocannon >/dev/null; then AC=autocannon; else AC="npx --yes autocannon"; fi
fi
URL=http://127.0.0.1:$PORT$URLPATH
[ $# -ge 2 ] || { sed -n 2,9p "$0"; exit 2; }
name=$1; shift
mkdir -p "$OUT"
if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null; then echo "!! $name: port $PORT already taken"; exit 1; fi
PORT=$PORT "$@" > "$OUT/$name.server.log" 2>&1 &
pid=$!
stop() { kill $pid 2>/dev/null; wait $pid 2>/dev/null; }
trap stop EXIT
for _ in $(seq 120); do
  curl -s -o /dev/null --max-time 1 "$URL" && break
  kill -0 $pid 2>/dev/null || { echo "!! server exited; see $OUT/$name.server.log"; exit 1; }
  sleep 1
done
owner=$(lsof -nP -t -iTCP:$PORT -sTCP:LISTEN | head -1)
echo "== $name (started pid $pid, port owner $owner)"
if [ "$owner" != "$pid" ]; then echo "!! port owner is not the server"; exit 1; fi
curl -si --max-time 2 "$URL" | tr -d '\r'; echo
$AC -c 10 -d 3 "$URL" > /dev/null 2>&1
wflag=""; [ "$WORKERS" -gt 1 ] && wflag="-w $WORKERS"
for run in $(seq "$RUNS"); do
  $AC -c "$CONNS" $wflag -d "$DURATION" -j "$URL" > "$OUT/$name.$run.json" 2>/dev/null
  node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1]));
    console.log(`run ${process.argv[2]}: ${Math.round(r.requests.average)} req/s, p99 ${r.latency.p99} ms, non2xx ${r.non2xx}, errors ${r.errors}, timeouts ${r.timeouts}`)' \
    "$OUT/$name.$run.json" "$run"
done
kill -0 $pid 2>/dev/null || { echo "!! server died during run"; exit 1; }
exit 0
