# [Platform support](@id platforms)

This page says where Facil and HttpTypes run, what is tested, and what to do
on a platform that is not supported.

## Summary

| | Facil | HttpTypes |
|:--|:--|:--|
| Linux x86_64 | supported, tested in CI | supported, tested in CI |
| macOS arm64 (Apple silicon) | supported, tested in CI | supported, tested in CI |
| macOS x86_64 (Intel) | supported, tested in CI | supported, tested in CI |
| Linux aarch64 | expected to work; not tested in CI | pure Julia; expected to work |
| Windows | **not supported**: use WSL2 | supported, tested in CI |
| FreeBSD and others | not tested | pure Julia; expected to work |

- **Julia versions:** 1.10 (the long-term support release) and the current
  release are tested on every supported platform. The minimum is 1.10.
- **Protocols:** HTTP/1.1 and HTTP/1.0, WebSocket (RFC 6455, with
  permessage-deflate), server-sent events, TLS 1.2 and 1.3 through the
  OpenSSL 3 that ships with Julia.

## Why not Windows

Facil's sockets, event loop and HTTP parser are [facil.io](https://github.com/boazsegev/facil.io),
a C library written for POSIX systems (epoll on Linux, kqueue on macOS). It
has no Windows port. Loading or building Facil on Windows stops with an error
that says so.

### Windows through WSL2

WSL2 runs a real Linux kernel, so Facil works there as on any Linux machine:

1. Install WSL2 and a distribution: `wsl --install` in an administrator
   PowerShell ([Microsoft's guide](https://learn.microsoft.com/windows/wsl/install)).
2. Inside the distribution, install Julia (for example with
   [juliaup](https://github.com/JuliaLang/juliaup)) and a compiler:
   `sudo apt-get install build-essential zlib1g-dev git`.
3. Follow [Install](../getting-started/install.md) inside WSL.
4. A server listening on `127.0.0.1:8080` inside WSL2 is reachable from
   Windows browsers and tools at `http://localhost:8080`.

Keep the project files inside the Linux file system (`~/...`), not under
`/mnt/c`, which is much slower.

This path is described from how WSL2 works; the project's CI does not run it.

**HttpTypes** is pure Julia with no dependencies and runs natively on
Windows, so code that only builds or inspects requests and responses can be
developed and tested there.

## How it is tested

Every push runs, on GitHub Actions:

- the Facil and HttpTypes test suites on Ubuntu (x86_64 and aarch64), macOS
  arm64 and macOS Intel, each with Julia 1.10 and the current release;
- the HttpTypes suite on Windows, plus a check that Facil refuses to load
  there with the WSL2 message;
- facil.io's patch test suites on Linux, which exercise the epoll and
  `sendfile` paths directly;
- this documentation, whose build starts every example program and checks
  its responses.

The [benchmarks](benchmarks.md) were measured on macOS only.

On aarch64 Linux the brotli *decoder* that Julia's `brotli_jll` package ships
rejects valid input (its encoder is fine, and Facil's responses are
byte-identical to those on other platforms). Facil only decodes brotli in
`Facil.unbrotli`, a helper for tests and clients; it detects the fault and
uses the system's `libbrotlidec` (package `libbrotli1` on Debian and Ubuntu)
instead.

## The C library

Facil loads `libfacil_julia`, built from facil.io (pinned at a fixed commit,
with the patches in `deps/patches`) and a small shim in `deps/shim`. Today it
is compiled on your machine the first time Facil is precompiled (by
`deps/build_local.jl`), which needs `clang` or `gcc`;
a prebuilt binary package (`facil_julia_jll`) is prepared but not published.
OpenSSL, zstd, brotli, libdeflate and zlib-ng come from Julia's binary
packages and need nothing from the system. The system's zlib is linked only
for facil.io's fallback WebSocket codec.
