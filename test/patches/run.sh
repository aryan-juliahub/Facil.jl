#!/usr/bin/env bash
# usage: run.sh [scratch_dir] [suite...]
# Applies deps/patches to a fresh copy of facil.io in <scratch_dir>, builds it
# with the flat compile flags, runs each suite and prints PASS/FAIL per test.
# Exits non-zero when anything fails. Suites use ports 3400-3419.
set -uo pipefail
T=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$T/../.." && pwd)
W=${1:-${TMPDIR:-/tmp}/facil-patches-test}
shift || true
SUITES=("$@")
[ ${#SUITES[@]} -gt 0 ] || SUITES=(robust large write upload features ws tls timers mixed spot fdreuse)

rm -rf "$W/src" "$W/build"
mkdir -p "$W"
"$ROOT/deps/patches/apply.sh" "$W/src" || { echo "FAIL  apply series"; exit 1; }
echo "PASS  apply series"
"$T/build.sh" "$W/src" "$W/build" || { echo "FAIL  build"; exit 1; }
echo "PASS  build  ($(grep -c 'warning:' "$W/build/warnings.log") compiler warnings, see $W/build/warnings.log)"

pass=0; fail=0
for s in "${SUITES[@]}"; do
  echo "== $s"
  mkdir -p "$W/$s"
  "$T/$s/run.sh" "$W/build" "$W/$s" 2>&1 | tee "$W/$s/output.txt" | grep -E '^(PASS|FAIL)  '
  p=$(grep -c '^PASS  ' "$W/$s/output.txt"); f=$(grep -c '^FAIL  ' "$W/$s/output.txt")
  [ "$p" -eq 0 ] && [ "$f" -eq 0 ] && { echo "FAIL  $s produced no results"; f=1; }
  pass=$((pass + p)); fail=$((fail + f))
done
echo "== total: $pass passed, $fail failed (logs in $W)"
[ "$fail" -eq 0 ]
