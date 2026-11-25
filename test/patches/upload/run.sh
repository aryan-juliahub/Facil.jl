#!/usr/bin/env bash
# usage: run.sh <build_dir> <work_dir>
# Request-body path (patch 08 with 06): every body mode, chunked framing,
# 100-continue, limits, stalls, disconnect churn, GC pressure, 1 GiB streams.
# Ports 3404-3406. GROUPS_ONLY=main,async,... runs a subset.
set -uo pipefail
S=$(cd "$(dirname "$0")" && pwd)
T=$(cd "$S/.." && pwd)
. "$T/common.sh"
B=$1; W=$2
mkdir -p "$W"
"$T/link.sh" "$B" "$S/shim.c" "$W/lib.dylib" || { result "upload: link shim" 1; exit 0; }

run() { # label port "server args" groups modes [env...]
  local label=$1 port=$2 args=$3 groups=$4 modes=$5 i; shift 5
  local log="$W/server.$port.$(echo "$label" | tr -c 'a-zA-Z0-9' _).log"
  if ! srv_start "$log" "$port" - "$JULIA" --startup-file=no -t 2 "$S/server.jl" "$port" "$W/lib.dylib" $args; then
    result "upload [$label] server start" 1; return
  fi
  for i in $(seq 300); do grep -q READY "$log" && break; sleep 0.1; done
  env SERVER_PID="$SRV_PID" "$@" python3 -I "$S/tests.py" "$port" "$groups" $modes 2>&1 |
    sed -E "s/^(PASS|FAIL|INFO) /\1  [$label] /" |
    awk '/^(PASS|FAIL)  /{print; next} /^INFO  /{sub(/^INFO  /,"info  "); print; next} {print "      " $0}'
  srv_alive || result "upload [$label] server still running at the end" 1
  srv_stop
}
ONLY=${GROUPS_ONLY:-all}
want() { [ "$ONLY" = all ] || [[ ",$ONLY," == *",$1,"* ]]; }
want main   && run "inline 1t C-malloc" 3404 "alloc=c" sizes,pipeline,splits,framing,expect,mv ""
want async  && run "async 4t jl-alloc" 3405 "alloc=jl threads=4 async=1" sizes,pipeline,splits ""
want async  && run "async 1t C-malloc" 3406 "alloc=c async=1" sizes,pipeline ""
want limits && run "limits 1MiB timeout 3s" 3404 "alloc=jl maxbody=1048576 timeout=3" limits,stall ""
want churn  && run "churn jl-alloc 1t" 3405 "alloc=jl timeout=3" churn,churn ""
want churn  && run "churn C-malloc 4t async" 3406 "alloc=c threads=4 async=1 timeout=3" churn ""
want gc     && run "gc 1t C inline" 3404 "alloc=c gcloop=1" gc "" GC_SECS=15
want gc     && run "gc 4t C async" 3405 "alloc=c threads=4 async=1 gcloop=1" gc "" GC_SECS=15
want gc     && run "gc 4t jl inline" 3406 "alloc=jl threads=4 gcloop=1" gc "" GC_SECS=15
want big1g  && run "1 GiB streamed" 3404 "maxbody=2147483648" big1g st
exit 0
