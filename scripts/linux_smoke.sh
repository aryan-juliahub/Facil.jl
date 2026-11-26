#!/usr/bin/env bash
# usage: scripts/linux_smoke.sh [--patches] [--julia110 <julia-1.10 binary>]
# Builds libfacil_julia on a Linux box or container and runs the Facil and
# HttpTypes suites, then (with --patches) the facil.io patch suites robust,
# upload, ws, tls and fdreuse. Needs: a C compiler, zlib headers, julia on PATH; for
# --patches also clang, node + npm, curl, lsof, python3 and openssl.
# Example (Debian/Ubuntu container, repo mounted at /src):
#   apt-get install -y build-essential zlib1g-dev clang curl lsof python3 openssl nodejs npm git
#   cd /src && scripts/linux_smoke.sh --patches
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
PATCHES=0
JULIA110=
while [ $# -gt 0 ]; do
  case $1 in
    --patches) PATCHES=1 ;;
    --julia110) JULIA110=$2; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

WORK=${WORK:-${TMPDIR:-/tmp}/facil-linux-smoke}
mkdir -p "$WORK"
step() { printf '\n== %s\n' "$*"; }

step "environment"
uname -a
[ -f /etc/os-release ] && . /etc/os-release && echo "$PRETTY_NAME"
ldd --version 2>&1 | head -1 || true
${CC:-cc} --version | head -1
julia --version
deps/fetch_facil.sh

step "build libfacil_julia"
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. deps/build_local.jl --verbose
julia --project=. -e 'using Facil; println(Facil.LIBFJL); println(Facil.fjl_build_id())'

step "HttpTypes tests"
julia --project=lib/HttpTypes -e 'using Pkg; Pkg.test()' 2>&1 | tee "$WORK/httptypes.log"

step "Facil tests (-t 4)"
julia -t 4 --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tee "$WORK/facil.log"

if [ -n "$JULIA110" ]; then
  step "Julia 1.10 (developed environment)"
  rm -rf "$WORK/env110"
  "$JULIA110" --project="$WORK/env110" -e '
    using Pkg
    Pkg.develop([PackageSpec(path="lib/HttpTypes"), PackageSpec(path=".")])
    Pkg.test("Facil"; julia_args=["-t", "4"])' 2>&1 | tee "$WORK/facil110.log"
fi

if [ "$PATCHES" = 1 ]; then
  step "facil.io patch suites"
  h=$(find deps/build "$HOME/.julia/artifacts" -path '*/include/openssl/opensslv.h' 2>/dev/null | head -1)
  [ -n "$h" ] || { echo "no OpenSSL headers found; set OPENSSL" >&2; exit 1; }
  export OPENSSL=${OPENSSL:-$(dirname "$(dirname "$(dirname "$h")")")}
  if [ -z "${NODE_MODULES:-}" ]; then
    mkdir -p "$WORK/node"
    (cd "$WORK/node" && { [ -f package.json ] || npm init -y >/dev/null; } && npm install ws@8 >/dev/null)
    export NODE_MODULES=$WORK/node/node_modules
  fi
  CC=clang test/patches/run.sh "$WORK/patches" robust upload ws tls fdreuse
fi

step "done; logs in $WORK"
