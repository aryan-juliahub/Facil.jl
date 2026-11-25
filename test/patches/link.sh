#!/usr/bin/env bash
# usage: link.sh <build_dir> <shim.c> <out.dylib> [extra clang flags]
# Links a fixture shim together with the merged facil.io objects, as one library.
set -euo pipefail
T=$(cd "$(dirname "$0")" && pwd)
. "$T/env.sh"
B=$1; shim=$2; out=$3; shift 3
INC=(); while IFS= read -r l; do INC+=("$l"); done < "$B/includes.txt"
clang "${FIO_CFLAGS[@]}" -w "${INC[@]}" "$@" "$shim" "$B"/obj/*.o -o "$out" "${FIO_LDFLAGS[@]}"
