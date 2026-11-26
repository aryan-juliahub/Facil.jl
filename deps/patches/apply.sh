#!/usr/bin/env bash
# usage: apply.sh <dest_dir>
# Copies deps/facil.io/lib (or $FACIL_IO_DIR/lib) to <dest_dir>/lib and applies every patch in
# `series`, in order. Exits non-zero if <dest_dir>/lib exists or a patch fails.
# Without $FACIL_IO_DIR, missing sources are fetched by deps/fetch_facil.sh first.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src=${FACIL_IO_DIR:-$here/../facil.io}/lib
[ $# -eq 1 ] || { echo "usage: $0 <dest_dir>" >&2; exit 2; }
dest=$1
[ -n "${FACIL_IO_DIR:-}" ] || [ -f "$src/facil/fio.c" ] || "$here/../fetch_facil.sh" >&2
[ -f "$src/facil/fio.c" ] || { echo "facil.io sources not found at $src" >&2; exit 1; }
[ -e "$dest/lib" ] && { echo "$dest/lib already exists" >&2; exit 1; }
mkdir -p "$dest"
cp -R "$src" "$dest/lib"
while IFS= read -r p || [ -n "$p" ]; do
  case "$p" in ''|'#'*) continue ;; esac
  patch -p1 -s -N -d "$dest" --no-backup-if-mismatch < "$here/$p" ||
    { echo "patch failed: $p" >&2; exit 1; }
done < "$here/series"
find "$dest/lib" \( -name '*.orig' -o -name '*.rej' \) -print | grep -q . &&
  { echo "leftover .orig/.rej files in $dest/lib" >&2; exit 1; }
exit 0
