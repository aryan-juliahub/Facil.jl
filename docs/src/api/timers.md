# [Timers](@id api-timers)

This page documents Facil's timing functions. They are timed by a dedicated
timer thread in the C library, which is accurate to tens of microseconds, and
they run your code on Julia tasks, never on the reactor thread. They work
without a server. The [timers guide](../guide/timers.md) shows them in use.

| Name | Unit | Use |
|:--|:--|:--|
| [`Facil.sleep`](@ref) | seconds | pause the current task |
| [`every`](@ref) | milliseconds | call a function repeatedly |
| [`Facil.Timer`](@ref) | seconds | call a function once after a delay, or repeatedly |

```@docs
Facil.sleep
every
Facil.Timer
```
