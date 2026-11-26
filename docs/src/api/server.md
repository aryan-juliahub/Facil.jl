# [Server](@id api-server)

This page documents how to start and stop a server: [`serve`](@ref) and
[`serve!`](@ref), the [`Server`](@ref) they create, and the functions that act
on it. For every keyword in one table, see
[Configuration](../reference/configuration.md); for when to use which, the
[handlers guide](../guide/handlers.md).

| Name | Use |
|:--|:--|
| [`serve`](@ref) | start a server and block; the last line of a server program |
| [`serve!`](@ref) | start a server and return it; for tests, the REPL, several servers |
| [`Server`](@ref) | the running server |
| [`close(server)`](@ref Base.close(::Server)) | stop it, optionally with a grace period |
| [`wait(server)`](@ref Base.wait(::Server)) | block until it has stopped |
| [`isopen(server)`](@ref Base.isopen(::Server)) | whether it still accepts connections |
| [`port(server)`](@ref HttpTypes.port(::Server)) | the port it listens on |
| [`Facil.connections(server)`](@ref Facil.connections) | its open connections |

```@docs
Facil
```

## Starting a server

```@docs
serve!
serve
```

## The `Server` object

```@docs
Server
Base.close(::Server)
Base.wait(::Server)
Base.isopen(::Server)
HttpTypes.port(::Server)
Facil.connections
Facil.drain_server!
```
