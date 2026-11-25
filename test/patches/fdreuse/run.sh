#!/usr/bin/env bash
# usage: run.sh <build_dir> <work_dir>   Descriptor reuse under connection churn
# (patch 14 on epoll, 03/04 on kqueue, 16): no keeper connection closed early or
# lost. FDREUSE_PORT picks the port, FDREUSE_RUNS repeats each case.
T=$(cd "$(dirname "$0")/.." && pwd); . "$T/common.sh"
B=$1; W=$2; mkdir -p "$W"
P=${FDREUSE_PORT:-3416}
SECS=${FDREUSE_SECONDS:-8}
INC=(); while IFS= read -r l; do INC+=("$l"); done < "$B/includes.txt"
clang -O2 -std=gnu11 -w "${INC[@]}" "$T/fdreuse/fdreuse.c" "$B"/obj/*.o -o "$W/fdreuse" "${FIO_EXE_LDFLAGS[@]}" ||
  { result "fdreuse: build" 1; exit 0; }
RUNS=${FDREUSE_RUNS:-1}
for mode in mixed fin; do
  for th in 4 8; do
    for r in $(seq "$RUNS"); do
      port_free "$P" || { result "fdreuse: port $P free" 1; exit 0; }
      out="$W/fdreuse_${mode}_${th}_$r"
      "$W/fdreuse" "$P" "$th" "$SECS" "$mode" > "$out.txt" 2> "$out.log" &
      pid=$!
      # a process stuck in the kernel ignores even SIGKILL: stop waiting for it
      for i in $(seq $(( ${SECS%.*} + 90 ))); do kill -0 $pid 2>/dev/null || break; sleep 1; done
      if kill -0 $pid 2>/dev/null; then
        command -v sample >/dev/null && sample $pid 2 -file "$out.sample.txt" >/dev/null 2>&1
        kill -9 $pid 2>/dev/null; echo "still running after $(( ${SECS%.*} + 90 )) s" >> "$out.txt"; rc=1
      else
        wait $pid; rc=$?
      fi
      [ $rc = 0 ] && [ "$(tail -1 "$out.txt")" = PASS ]
      result "fdreuse: no keeper closed or lost under $mode churn, $th reactor threads, run $r" $? "$(head -1 "$out.txt")"
    done
  done
done
