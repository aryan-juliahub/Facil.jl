#!/usr/bin/env bash
# usage: build.sh <src_root> <out_dir>
# Compiles <src_root>/lib/facil (all .c except legacy) with the flat command's
# flags into <out_dir>/obj and links <out_dir>/libfacil.dylib. Compiler
# diagnostics go to <out_dir>/warnings.log.
set -euo pipefail
T=$(cd "$(dirname "$0")" && pwd)
. "$T/env.sh"
SRC=$(cd "$1" && pwd)/lib/facil
OUT=$2
rm -rf "$OUT/obj"; mkdir -p "$OUT/obj"
INC=(-I"$SRC" -I"$SRC/fiobj" -I"$SRC/http" -I"$SRC/http/parsers" -I"$SRC/cli" -I"$SRC/tls" -I"$SRC/redis")
: > "$OUT/warnings.log"
objs=()
for c in $(find "$SRC" -name '*.c' -not -path '*/legacy/*' | sort); do
  rel=${c#$SRC/}; o="$OUT/obj/${rel//\//_}"; o=${o%.c}.o
  clang "${FIO_CFLAGS[@]}" "${INC[@]}" -c "$c" -o "$o" 2>>"$OUT/warnings.log" &
  objs+=("$o")
  while [ "$(jobs -r | wc -l)" -ge 8 ]; do sleep 0.05; done
done
wait
for o in "${objs[@]}"; do [ -f "$o" ] || { echo "compile failed: $o" >&2; cat "$OUT/warnings.log" >&2; exit 1; }; done
printf '%s\n' "${INC[@]}" > "$OUT/includes.txt"
clang "${objs[@]}" -o "$OUT/libfacil.dylib" ${SONAME_FLAGS[@]+"${SONAME_FLAGS[@]}"} "${FIO_LDFLAGS[@]}"
