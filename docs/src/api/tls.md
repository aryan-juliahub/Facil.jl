# [HTTPS](@id api-tls)

This page documents serving HTTPS: [`TLSConfig`](@ref) describes the
certificates and protocol settings, `serve!(...; tls = config)` uses it, and
[`reload!`](@ref) swaps a certificate on a running server. The
[HTTPS guide](../guide/tls.md) covers creating certificates and testing.

```@docs
TLSConfig
reload!
TLSError
```
