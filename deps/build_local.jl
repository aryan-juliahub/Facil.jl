#!/usr/bin/env julia
# Builds deps/usr/lib/libfacil_julia.{dylib,so} from facil.io (plus deps/patches,
# when present) and deps/shim/*.c with the system C compiler.
# Usage: julia --project=. deps/build_local.jl [--force] [--verbose]
# When deps/ is read-only it builds into a scratchspace instead.
# src/libfjl.jl includes this file and calls build() when Facil is precompiled
# without facil_julia_jll, so an installed package builds itself on first load.
# It is not named build.jl: Pkg.build cannot run for a package whose
# [sources] has a path entry (Julia 1.11 to 1.13).

Sys.iswindows() && error("Facil.jl requires Linux or macOS (facil.io has no Windows support); on Windows use WSL2. HttpTypes.jl works on Windows.")

using Libdl, SHA, OpenSSL_jll, Scratch, TOML

const DEPS = @__DIR__
const PROJECT = TOML.parsefile(joinpath(dirname(DEPS), "Project.toml"))
const PATCHES = joinpath(DEPS, "patches")
const SHIM = joinpath(DEPS, "shim")

const FACIL_COMMIT = "5128747363055201d3ecf0e29bf0a961703c9fa0"
const FACIL_TARBALL_SHA256 = "93197373e139f0b43802f139472ed9eaac5082a949d20bacfb4ec9934ddda569"

function deps_writable()
    try
        probe = joinpath(DEPS, ".write-probe-$(getpid())")
        touch(probe)
        rm(probe)
        true
    catch
        false
    end
end

const WRITABLE = deps_writable()
const ROOT = WRITABLE ? DEPS : get_scratch!(Base.UUID(PROJECT["uuid"]), "libfacil_julia")
const BUILD = joinpath(ROOT, "build")
const LIBDIR = WRITABLE ? joinpath(DEPS, "usr", "lib") : joinpath(ROOT, "lib")
const LIBNAME = "libfacil_julia." * Libdl.dlext
const LIBPATH = joinpath(LIBDIR, LIBNAME)
const STAMP = LIBPATH * ".sha256"

const AS_SCRIPT = abspath(PROGRAM_FILE) == abspath(@__FILE__)
const FORCE = AS_SCRIPT && "--force" in ARGS
const VERBOSE = AS_SCRIPT && "--verbose" in ARGS
FACIL::String = ""

# Headers matching Julia's OpenSSL 3; used only when no local artifact has them.
const OPENSSL_HEADERS_VERSION = "3.5.9"
const OPENSSL_HEADERS = Dict(
    "aarch64-apple-darwin" => "c032656be399deea6e144baa7e24fa1105eeaf9cec94279c1de685adb94bc52d",
    "x86_64-apple-darwin" => "a97bcbf36aeebc04bb083d3596106672ab93c0865aab9113fffa25f1d114ef94",
    "aarch64-linux-gnu" => "066a40cee76b28acb6781d01d0354a2e3f7b0514c856e3ca953f48fe6b217a59",
    "aarch64-linux-musl" => "cb080dfd722dea5f1a31b8ad479145a8bfc5e5b398ed7932907f98956e7ce270",
    "x86_64-linux-gnu" => "8e2c75378726017fc66fb7fbbd10fb53522417c3e45a88af77b8853d46f2b063",
    "x86_64-linux-musl" => "4c01eb9d07ed91a3b3bc0e900b723b36c79cc51df83b4cdda129b4ed08b318c1",
)

log(a...) = (println(stderr, "[facil build] ", a...); flush(stderr))

function files_under(root)
    out = String[]
    isdir(root) || return out
    for (dir, _, fs) in walkdir(root), f in fs
        push!(out, joinpath(dir, f))
    end
    sort!(out)
end

function openssl_major_minor(include_dir)
    h = joinpath(include_dir, "openssl", "opensslv.h")
    isfile(h) || return nothing
    s = read(h, String)
    ma = match(r"#\s*define\s+OPENSSL_VERSION_MAJOR\s+(\d+)", s)
    mi = match(r"#\s*define\s+OPENSSL_VERSION_MINOR\s+(\d+)", s)
    (ma === nothing || mi === nothing) && return nothing
    (parse(Int, ma[1]), parse(Int, mi[1]))
end

function runtime_openssl()
    lib = Libdl.dlopen(OpenSSL_jll.libcrypto_path)
    v = ccall(Libdl.dlsym(lib, :OpenSSL_version_num), Culong, ())
    (Int(v >> 28), Int((v >> 20) & 0xff))
end

function triplet()
    arch = Sys.ARCH === :aarch64 ? "aarch64" : string(Sys.ARCH)
    Sys.isapple() && return "$arch-apple-darwin"
    libc = isfile("/lib/ld-musl-$(arch).so.1") ? "musl" : "gnu"
    "$arch-linux-$libc"
end

function download_headers()
    t = triplet()
    haskey(OPENSSL_HEADERS, t) || error("no OpenSSL headers known for $t; set FACIL_OPENSSL_INCLUDE")
    dest = joinpath(BUILD, "openssl-$OPENSSL_HEADERS_VERSION")
    inc = joinpath(dest, "include")
    isfile(joinpath(inc, "openssl", "ssl.h")) && return inc
    v = OPENSSL_HEADERS_VERSION
    url = "https://github.com/JuliaBinaryWrappers/OpenSSL_jll.jl/releases/download/OpenSSL-v$v+0/OpenSSL.v$v.$t.tar.gz"
    mkpath(BUILD)
    tarball = joinpath(BUILD, "openssl-$v.tar.gz")
    log("downloading OpenSSL headers: ", url)
    Base.download(url, tarball)
    bytes2hex(open(sha256, tarball)) == OPENSSL_HEADERS[t] || error("checksum mismatch for $tarball")
    mkpath(dest)
    run(`tar -xzf $tarball -C $dest include`)
    rm(tarball)
    inc
end

function openssl_include()
    haskey(ENV, "FACIL_OPENSSL_INCLUDE") && return ENV["FACIL_OPENSSL_INCLUDE"]
    want = runtime_openssl()
    jll = joinpath(OpenSSL_jll.artifact_dir, "include")
    openssl_major_minor(jll) == want && return jll
    for depot in DEPOT_PATH
        arts = joinpath(depot, "artifacts")
        isdir(arts) || continue
        for d in readdir(arts; join=true)
            inc = joinpath(d, "include")
            openssl_major_minor(inc) == want && isfile(joinpath(inc, "openssl", "ssl.h")) && return inc
        end
    end
    download_headers()
end

# The facil.io sources: deps/facil.io when deps/fetch_facil.sh put them there,
# else a verified GitHub tarball unpacked in the build directory.
function facil_source()
    sub = joinpath(DEPS, "facil.io")
    isfile(joinpath(sub, "lib", "facil", "fio.c")) && return sub
    dest = joinpath(BUILD, "facil.io-$FACIL_COMMIT")
    isfile(joinpath(dest, "lib", "facil", "fio.c")) && return dest
    url = "https://github.com/boazsegev/facil.io/archive/$FACIL_COMMIT.tar.gz"
    mkpath(BUILD)
    tarball = joinpath(BUILD, "facil.io.tar.gz")
    log("downloading facil.io sources: ", url)
    Base.download(url, tarball)
    bytes2hex(open(sha256, tarball)) == FACIL_TARBALL_SHA256 || error("checksum mismatch for $tarball")
    run(`tar -xzf $tarball -C $BUILD`)
    rm(tarball)
    dest
end

function facil_commit()
    ispath(joinpath(FACIL, ".git")) || return FACIL_COMMIT[1:8]
    try
        readchomp(`git -C $FACIL rev-parse --short=8 HEAD`)
    catch
        "unknown"
    end
end

function prepare_sources(src)
    rm(src; force=true, recursive=true)
    mkpath(src)
    apply = joinpath(PATCHES, "apply.sh")
    if isfile(apply)
        log("applying patch series: ", apply)
        run(pipeline(addenv(`bash $apply $src`, "FACIL_IO_DIR" => FACIL); stdout=VERBOSE ? stdout : devnull))
        return true
    end
    cp(joinpath(FACIL, "lib"), joinpath(src, "lib"))
    false
end

function compile_all(cc, jobs::Vector{Cmd})
    sem = Base.Semaphore(max(1, Sys.CPU_THREADS))
    failed = Threads.Atomic{Int}(0)
    @sync for cmd in jobs
        @async Base.acquire(sem) do
            VERBOSE && log(cmd)
            p = run(pipeline(ignorestatus(cmd); stderr=stderr))
            success(p) || Threads.atomic_add!(failed, 1)
        end
    end
    failed[] == 0 || error("$(failed[]) compile step(s) failed")
end

# The files whose content decides whether the library is rebuilt, besides facil.io.
build_inputs() = vcat(files_under(PATCHES), files_under(SHIM), [@__FILE__])

function build()
    global FACIL = facil_source()
    cc = get(ENV, "CC", "cc")
    inc_ssl = openssl_include()
    libssl, libcrypto = OpenSSL_jll.libssl_path, OpenSSL_jll.libcrypto_path
    have_patches = isfile(joinpath(PATCHES, "apply.sh"))

    inputs = vcat(files_under(joinpath(FACIL, "lib")), build_inputs())
    ctx = SHA.SHA256_CTX()
    for f in inputs
        SHA.update!(ctx, codeunits(startswith(f, FACIL) ? joinpath("facil.io", relpath(f, FACIL)) : relpath(f, DEPS)))
        SHA.update!(ctx, read(f))
    end
    SHA.update!(ctx, codeunits(join((cc, inc_ssl, libssl, libcrypto, string(Sys.ARCH)), '\0')))
    digest = bytes2hex(SHA.digest!(ctx))

    if !FORCE && isfile(LIBPATH) && isfile(STAMP) && readchomp(STAMP) == digest
        AS_SCRIPT && log("up to date: ", LIBPATH)
        return LIBPATH
    end

    t0 = time()
    src = joinpath(BUILD, "src")
    patched = prepare_sources(src)
    facil = joinpath(src, "lib", "facil")
    isfile(joinpath(facil, "fio.c")) || error("facil.io sources missing in $facil")

    patch_tag = patched ? "patches-" * bytes2hex(sha256(join(read.(files_under(PATCHES)))))[1:8] : "stock"
    build_id = "facil.io $(facil_commit()) $patch_tag"

    incs = ["-I$facil"; ["-I" * joinpath(facil, d) for d in ("fiobj", "http", "http/parsers", "cli", "tls", "redis")]; "-I$SHIM"; "-I$inc_ssl"]
    defs = ["-DHAVE_OPENSSL", "-DFIO_TLS_FOUND", "-DFJL_BUILD_ID=\"$build_id\""]
    Sys.islinux() && append!(defs, ["-DHAVE_TM_TM_ZONE=1", "-D_LARGEFILE64_SOURCE"])
    cflags = ["-fPIC", "-O2", "-DNDEBUG", "-std=gnu11"]

    objdir = joinpath(BUILD, "obj")
    rm(objdir; force=true, recursive=true)
    mkpath(objdir)
    csrc = filter(f -> endswith(f, ".c") && !occursin("/legacy/", f), files_under(facil))
    shim = filter(f -> endswith(f, ".c"), files_under(SHIM))
    jobs = Cmd[]
    objs = String[]
    for (i, f) in enumerate(vcat(csrc, shim))
        o = joinpath(objdir, string(i, "_", splitext(basename(f))[1], ".o"))
        warn = f in shim ? ["-Wall", "-Wextra", "-Wno-unused-parameter"] : ["-w"]
        push!(jobs, `$cc $cflags $warn $defs $incs -c $f -o $o`)
        push!(objs, o)
    end
    compile_all(cc, jobs)

    mkpath(LIBDIR)
    tmp = LIBPATH * ".tmp$(getpid())"
    ldflags = ["-shared", "-Wl,-rpath," * dirname(libssl)]
    Sys.isapple() && push!(ldflags, "-Wl,-install_name,@rpath/$LIBNAME")
    run(`$cc $ldflags -o $tmp $objs $libssl $libcrypto -lz -lpthread -lm`)
    mv(tmp, LIBPATH; force=true)
    write(STAMP, digest * "\n")
    log("built ", LIBPATH, " (", build_id, ", ", length(objs), " objects, ", round(time() - t0; digits=1), " s)")
    LIBPATH
end

AS_SCRIPT && build()
