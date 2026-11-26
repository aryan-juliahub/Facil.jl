# [Install](@id install)

This page gets Facil onto your machine and checks that it works. It takes
about five minutes, most of it Julia precompiling.

## What you need

- **Julia 1.10 or later.** Facil is tested on Julia 1.10 and on the current
  release.
- **Linux or macOS.** On Windows, run Facil inside
  [WSL2](https://learn.microsoft.com/windows/wsl/install); see
  [Platform support](../reference/platforms.md).
- **A C compiler** (`clang` or `gcc`) and **git**. Facil's C library is built
  on your machine for now, because the prebuilt binary package is not
  published yet. On Debian or Ubuntu also install the zlib headers:
  `sudo apt-get install build-essential zlib1g-dev`. On macOS,
  `xcode-select --install` provides everything.

!!! note "Facil is not in the General registry yet"
    `Pkg.add("Facil")` does not work yet, and neither does
    `Pkg.add(url = ...)`: the repository carries facil.io as a git submodule,
    which Pkg cannot fetch. Until the package is registered, install from a
    clone as shown here.

## 1. Clone and build

```sh
git clone --recurse-submodules https://github.com/aryan-juliahub/Facil.jl
julia --project=Facil.jl -e 'using Pkg; Pkg.instantiate()'
julia --project=Facil.jl Facil.jl/deps/build.jl
```

The last command compiles facil.io and Facil's C shim into
`Facil.jl/deps/usr/lib/` and prints the path of the library it built. It takes
a few seconds.

If you forgot `--recurse-submodules`, run
`git -C Facil.jl submodule update --init` and build again.

## 2. Add Facil to your project

Facil depends on HttpTypes, which lives in the same repository. From the
directory of your own project, add both by path:

```sh
mkdir myapp && cd myapp
julia --project=. -e 'using Pkg; Pkg.develop([PackageSpec(path="../Facil.jl/lib/HttpTypes"), PackageSpec(path="../Facil.jl")])'
```

## 3. Check that it works

Save this as `hello.jl` in your project:

```@eval
Main.example("hello.jl")
```

Run it with four Julia threads:

```sh
julia -t 4 --project=. hello.jl
```

From another terminal:

```sh
$ curl http://127.0.0.1:8080/
hello
```

Stop the server with Ctrl-C. Julia prints a `signal 2: Interrupt` report
when a script is interrupted; that is normal. [Shutdown and signals](../guide/shutdown.md)
explains how to stop a server quietly.

!!! tip "Always pass `-t`"
    Start Julia with more than one thread (`-t 4`, or `-t auto`). With a
    single thread Facil runs every handler on its event-loop thread, where a
    handler that waits for anything stalls all connections.
    [Handlers and concurrency](../guide/handlers.md) explains the two modes.

## If something goes wrong

| Message | Cause and fix |
|:--|:--|
| `libfacil_julia... is missing; build it with ...` | Step 1's build did not run or failed. Run `julia --project=Facil.jl Facil.jl/deps/build.jl --verbose`. |
| `cannot get submodules without a working tree` | You used `Pkg.add(url = ...)`. Clone the repository instead. |
| `expected package HttpTypes to exist at path ...` | You ran `Pkg.build("Facil")` from your project. Build with `deps/build.jl` as in step 1. |
| `fatal error: 'zlib.h' file not found` | Install the zlib headers (`zlib1g-dev` on Debian and Ubuntu). |
| `Facil.jl requires Linux or macOS` | You are on Windows outside WSL2. |
| `Address already in use` | Another program holds port 8080. Pick another port, or see the [FAQ](../reference/faq.md). |

## Next

- [Your first server](first-server.md) explains the five lines you just ran.
- [Tutorial: a JSON API](tutorial.md) builds a small real service in ten minutes.
