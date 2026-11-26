# [Install](@id install)

This page gets Facil onto your machine and checks that it works. It takes
a few minutes, most of it Julia precompiling.

## What you need

- **Julia 1.10 or later.** Facil is tested on Julia 1.10 and on the current
  release.
- **Linux or macOS.** On Windows, run Facil inside
  [WSL2](https://learn.microsoft.com/windows/wsl/install); see
  [Platform support](../reference/platforms.md).
- **A C compiler** (`clang` or `gcc`) and a network connection. Facil's C
  library is built on your machine for now, because the prebuilt binary
  package is not published yet. On Debian or Ubuntu also install the zlib
  headers: `sudo apt-get install build-essential zlib1g-dev`. On macOS,
  `xcode-select --install` provides everything.

!!! note "Facil is not in the General registry yet"
    `Pkg.add("Facil")` does not work yet. Until the package is registered,
    add it by URL as shown here.

## 1. Add Facil to your project

Facil depends on HttpTypes, which lives in the same repository, so add both:

```sh
mkdir myapp && cd myapp
julia --project=. -e 'using Pkg; Pkg.add([PackageSpec(url="https://github.com/aryan-juliahub/Facil.jl", subdir="lib/HttpTypes"), PackageSpec(url="https://github.com/aryan-juliahub/Facil.jl")])'
```

On Julia 1.13 the short form is enough, because Pkg reads where HttpTypes
lives from Facil's own project file:

```sh
julia --project=. -e 'using Pkg; Pkg.add(url="https://github.com/aryan-juliahub/Facil.jl")'
```

## 2. Let it build

```sh
julia --project=. -e 'using Facil'
```

The first time Facil is loaded, Julia precompiles it, and that step compiles
the C library: it downloads the facil.io sources (a pinned commit, checked
against a SHA-256), applies Facil's patches and compiles them with Facil's C
shim. It prints a few `[facil build]` lines and takes under a minute. Later
loads print nothing.

!!! note "Working on Facil itself"
    Clone the repository instead and use its own project:
    `git clone https://github.com/aryan-juliahub/Facil.jl`, then
    `julia --project=Facil.jl -e 'using Pkg; Pkg.instantiate(); using Facil'`.
    `AGENTS.md` in the repository has the contributor workflow.

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
| `[facil build] ... compile step(s) failed` while precompiling | The C compiler is missing or failed. Install one (see above), then run `using Facil` again. |
| `checksum mismatch` or a download error while precompiling | The facil.io sources could not be fetched from GitHub. Check the network and run `using Facil` again. |
| `Unsatisfiable requirements detected for package HttpTypes` | You used the short `Pkg.add(url = ...)` on Julia 1.10. Use the two-package command of step 1. |
| `fatal error: 'zlib.h' file not found` | Install the zlib headers (`zlib1g-dev` on Debian and Ubuntu). |
| `Facil.jl requires Linux or macOS` | You are on Windows outside WSL2. |
| `Address already in use` | Another program holds port 8080. Pick another port, or see the [FAQ](../reference/faq.md). |

## Next

- [Your first server](first-server.md) explains the five lines you just ran.
- [Tutorial: a JSON API](tutorial.md) builds a small real service in ten minutes.
