#!/usr/bin/env sh
# Refreshes bundled/ in the Yggdrasil recipe from deps/patches and deps/shim.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
b=$here/F/facil_julia/bundled
rm -rf "$b"
mkdir -p "$b/patches" "$b/shim"
cp "$here"/../patches/*.patch "$here"/../patches/series "$b/patches/"
cp "$here"/../shim/*.c "$here"/../shim/*.h "$b/shim/"
