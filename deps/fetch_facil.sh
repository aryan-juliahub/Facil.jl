#!/usr/bin/env bash
# usage: fetch_facil.sh
# Puts the pinned facil.io sources in deps/facil.io: downloads the commit's
# tarball from GitHub, checks its SHA-256 and unpacks it. Does nothing when
# the sources are already there. deps/build_local.jl does not need this; the
# patch tooling (deps/patches/apply.sh, test/patches) does.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
commit=5128747363055201d3ecf0e29bf0a961703c9fa0
sha256=93197373e139f0b43802f139472ed9eaac5082a949d20bacfb4ec9934ddda569
dest=$here/facil.io
[ -f "$dest/lib/facil/fio.c" ] && exit 0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL --retry 3 -o "$tmp/facil.tar.gz" "https://github.com/boazsegev/facil.io/archive/$commit.tar.gz"
if command -v sha256sum >/dev/null 2>&1; then
  got=$(sha256sum "$tmp/facil.tar.gz" | cut -d' ' -f1)
else
  got=$(shasum -a 256 "$tmp/facil.tar.gz" | cut -d' ' -f1)
fi
[ "$got" = "$sha256" ] || { echo "checksum mismatch for the facil.io tarball: $got" >&2; exit 1; }
tar -xzf "$tmp/facil.tar.gz" -C "$tmp"
rm -rf "$dest"
mv "$tmp/facil.io-$commit" "$dest"
echo "facil.io $commit unpacked in $dest"
