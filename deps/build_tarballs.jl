# BinaryBuilder recipe for facil_julia_jll: facil.io 51287473 with deps/patches
# applied in `series` order, plus deps/shim/*.c, as one shared library.
# Run from a machine where BinaryBuilder works (Linux x86_64 with its sandbox):
#   julia --project=<env with BinaryBuilder> deps/build_tarballs.jl --verbose --debug
# The submitted copy is deps/yggdrasil/F/facil_julia/build_tarballs.jl; the build
# script below must stay identical in both files.
using BinaryBuilder, Pkg

name = "facil_julia"
version = v"0.1.0"

const FACIL_COMMIT = "5128747363055201d3ecf0e29bf0a961703c9fa0"

# macOS x86_64 needs clock_gettime (10.12+); Julia 1.10 itself needs 10.14.
const MACOS_SDK = FileSource(
    "https://github.com/phracker/MacOSX-SDKs/releases/download/10.15/MacOSX10.14.sdk.tar.xz",
    "0f03869f72df8705b832910517b47dd5b79eb4e160512602f593ed243b28715f")

sources = [
    GitSource("https://github.com/boazsegev/facil.io.git", FACIL_COMMIT),
    DirectorySource(joinpath(@__DIR__, "patches"); target = "patches"),
    DirectorySource(joinpath(@__DIR__, "shim"); target = "shim"),
    MACOS_SDK,
]

sdk_script = raw"""
mv ${WORKSPACE}/srcdir/MacOSX10.14.sdk.tar.xz ${WORKSPACE}/
if [[ "${target}" == x86_64-apple-darwin* ]]; then
    tar --extract --file=${WORKSPACE}/MacOSX10.14.sdk.tar.xz --directory=${WORKSPACE} --warning=no-unknown-keyword
    old_sdkroot=${SDKROOT}
    new_sdkroot=${WORKSPACE}/MacOSX10.14.sdk
    ln -sT ${old_sdkroot}/usr/local ${new_sdkroot}/usr/local
    sed -i -e "s+${old_sdkroot}+${new_sdkroot}+" $(find /opt/bin/${target}* -type f -print)
    SDKROOT=${new_sdkroot}
    export MACOSX_DEPLOYMENT_TARGET=10.14
fi
"""

script = sdk_script * raw"""
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
