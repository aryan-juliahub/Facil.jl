#!/usr/bin/env bash
# usage: run.sh <build_dir> <work_dir>   Timer accuracy and idle CPU (patch 02).
T=$(cd "$(dirname "$0")/.." && pwd); . "$T/common.sh"
B=$1; W=$2; mkdir -p "$W"
INC=(); while IFS= read -r l; do INC+=("$l"); done < "$B/includes.txt"
clang -O2 -std=gnu11 -w "${INC[@]}" "$T/timers/timers.c" "$B"/obj/*.o -o "$W/timers" "${FIO_EXE_LDFLAGS[@]}" ||
  { result "timers: build" 1; exit 0; }
out=$("$W/timers" 2>"$W/timers.log"); echo "$out" > "$W/timers.txt"
med() { echo "$out" | awk -v k="$1" '$0 ~ k { print $(NF-2) }'; }
check() { awk -v v="$2" -v lim="$3" 'BEGIN { exit !(v != "" && v <= lim) }'; result "$1" $? "median $2 ms, limit $3"; }
check "timers: 1 ms one-shot" "$(med 'timer 1 ms busy 0')" 1.25
check "timers: 10 ms one-shot" "$(med 'timer 10 ms busy 0')" 10.4
check "timers: 10 ms armed inside a busy task" "$(med 'timer 10 ms busy 5')" 10.4
cpu=$(echo "$out" | awk '/idle cpu/ { sub("%", "", $NF); print $NF }')
awk -v v="$cpu" 'BEGIN { exit !(v < 1.0) }'; result "timers: no busy poll with a sub-second timer pending" $? "cpu $cpu%"
