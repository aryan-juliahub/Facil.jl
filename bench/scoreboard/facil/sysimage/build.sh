#!/usr/bin/env bash
# Builds facil/sysimage/facil_sys.dylib (PackageCompiler sysimage with Facil and JSON) for the *-sysimg rows.
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd)
julia --project="$D" -e 'using Pkg; Pkg.add("PackageCompiler")'
julia --project="$D" -e 'using PackageCompiler
create_sysimage([:Facil, :JSON]; sysimage_path = joinpath(ARGS[1], "facil_sys.dylib"),
    project = ARGS[2], precompile_execution_file = joinpath(ARGS[1], "warm.jl"))' "$D" "$D/.."
