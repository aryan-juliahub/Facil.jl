# Server helpers for the patch suites. Sourced by each suite's run.sh.
# Ports 3400-3419 only. A started server is killed by its own pid only.
T=${T:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
. "$T/env.sh"
export NODE_NO_WARNINGS=1
ulimit -n 65536 2>/dev/null || ulimit -n 10240 2>/dev/null || true

port_free() { ! lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }
port_owner() { lsof -nP -t -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | head -1; }

# srv_start <logfile> <port> <probe_path|-> <cmd...>: sets SRV_PID; fails if the
# port is taken, the server dies, or another process owns the listener.
srv_start() {
  local log=$1 port=$2 probe=$3 i; shift 3
  case $port in 340[0-9]|341[0-9]) ;; *) echo "port $port outside 3400-3419" >&2; return 1 ;; esac
  port_free "$port" || { echo "port $port taken by pid $(port_owner "$port")" >&2; return 1; }
  "$@" > "$log" 2>&1 &
  SRV_PID=$!
  for i in $(seq 300); do
    [ -n "$(port_owner "$port")" ] && break
    kill -0 "$SRV_PID" 2>/dev/null || { echo "server died at start:" >&2; tail -20 "$log" >&2; return 1; }
    sleep 0.1
  done
  [ "$(port_owner "$port")" = "$SRV_PID" ] || { echo "listener on $port is '$(port_owner "$port")', expected $SRV_PID" >&2; kill -9 "$SRV_PID" 2>/dev/null; return 1; }
  if [ "$probe" != - ]; then
    for i in $(seq 100); do curl -sk -o /dev/null --max-time 1 "$probe" && break; sleep 0.1; done
  fi
  return 0
}

# srv_alive: true while the last started server runs.
srv_alive() { kill -0 "$SRV_PID" 2>/dev/null; }

# srv_stop: TERM, then KILL after 3 s, then waits for the port to free up.
srv_stop() {
  local i
  [ -n "${SRV_PID:-}" ] || return 0
  kill "$SRV_PID" 2>/dev/null
  for i in $(seq 30); do kill -0 "$SRV_PID" 2>/dev/null || break; sleep 0.1; done
  kill -9 "$SRV_PID" 2>/dev/null
  wait "$SRV_PID" 2>/dev/null
  SRV_PID=
}

# result <name> <ok:0|1> [detail]: one PASS/FAIL line, counted by run.sh.
result() {
  if [ "$2" = 0 ]; then echo "PASS  $1${3:+  ($3)}"; else echo "FAIL  $1${3:+  ($3)}"; fi
}
