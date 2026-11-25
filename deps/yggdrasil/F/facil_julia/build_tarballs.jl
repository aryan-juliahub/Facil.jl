# facil_julia_jll: facil.io with the Facil.jl patch series and C shim.
# Upstream sources of truth: deps/patches and deps/shim in Facil.jl; bundled/
# holds copies of both. Keep the build script identical to deps/build_tarballs.jl.
using BinaryBuilder, Pkg

const YGGDRASIL_DIR = "../.."
include(joinpath(YGGDRASIL_DIR, "platforms", "macos_sdks.jl"))

name = "facil_julia"
version = v"0.1.0"

const FACIL_COMMIT = "5128747363055201d3ecf0e29bf0a961703c9fa0"

sources = [
    GitSource("https://github.com/boazsegev/facil.io.git", FACIL_COMMIT),
    DirectorySource("./bundled"),
]

script = raw"""
cd ${WORKSPACE}/srcdir/facil.io
while IFS= read -r p || [[ -n "${p}" ]]; do
    case "${p}" in ''|'#'*) continue ;; esac
    atomic_patch -p1 "${WORKSPACE}/srcdir/patches/${p}"
done < "${WORKSPACE}/srcdir/patches/series"

F=lib/facil
SHIM=${WORKSPACE}/srcdir/shim
FLAGS=(-fPIC -O2 -DNDEBUG -std=gnu11)
Q='"'
DEFS=(-DHAVE_OPENSSL -DFIO_TLS_FOUND "-DFJL_BUILD_ID=${Q}facil.io ${FACIL_COMMIT:0:8} facil_julia_jll${Q}")
if [[ "${target}" == *-linux-* ]]; then
    DEFS+=(-DHAVE_TM_TM_ZONE=1 -D_LARGEFILE64_SOURCE)
fi
INCS=(-I${F} -I${F}/fiobj -I${F}/http -I${F}/http/parsers -I${F}/cli -I${F}/tls -I${F}/redis -I${SHIM} -I${includedir})

mkdir -p obj
objs=()
i=0
for c in $(find ${F} -name '*.c' -not -path '*/legacy/*' | sort) ${SHIM}/*.c; do
    i=$((i + 1))
    o="obj/${i}_$(basename ${c} .c).o"
    if [[ "${c}" == ${SHIM}/* ]]; then
        W=(-Wall -Wextra -Wno-unused-parameter)
    else
        W=(-w)
    fi
    ${CC} "${FLAGS[@]}" "${W[@]}" "${DEFS[@]}" "${INCS[@]}" -c "${c}" -o "${o}"
    objs+=("${o}")
done

LDFLAGS=(-shared)
if [[ "${target}" == *-apple-* ]]; then
    LDFLAGS+=(-Wl,-install_name,@rpath/libfacil_julia.${dlext})
else
    LDFLAGS+=(-Wl,-soname,libfacil_julia.${dlext})
fi
mkdir -p ${libdir}
${CC} "${LDFLAGS[@]}" -o ${libdir}/libfacil_julia.${dlext} "${objs[@]}" -L${libdir} -lssl -lcrypto -lz -lpthread -lm
install_license LICENSE
"""
script = "FACIL_COMMIT=$(FACIL_COMMIT)\n" * script

# macOS x86_64 needs clock_gettime (10.12+); Julia 1.10 itself needs 10.14.
sources, script = require_macos_sdk("10.14", sources, script)

# fjl_timer.c supports macOS (kqueue) and Linux (timerfd) only.
platforms = [
    Platform("x86_64", "linux"; libc = "glibc"),
    Platform("aarch64", "linux"; libc = "glibc"),
    Platform("x86_64", "linux"; libc = "musl"),
    Platform("aarch64", "linux"; libc = "musl"),
    Platform("x86_64", "macos"),
    Platform("aarch64", "macos"),
]

products = [
    LibraryProduct("libfacil_julia", :libfacil_julia),
]

# Built against OpenSSL 3.0 headers; OpenSSL 3.x keeps ABI within the major
# version, so the library also runs on the 3.5 that Julia >= 1.12 ships.
dependencies = [
    Dependency("OpenSSL_jll"; compat = "3.0.16"),
    Dependency("Zlib_jll"),
]

# C11 atomics in the shim need GCC >= 4.9.
build_tarballs(ARGS, name, version, sources, script, platforms, products, dependencies;
               julia_compat = "1.10", preferred_gcc_version = v"10")
