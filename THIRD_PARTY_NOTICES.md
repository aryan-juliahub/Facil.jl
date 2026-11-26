# Third-party notices

Facil.jl includes code from the projects below. Each keeps its own licence.

## facil.io

Facil.jl builds facil.io (fetched at a pinned commit by `deps/build_local.jl`
or `deps/fetch_facil.sh`, with the patches in `deps/patches`) into its native
library. Licence: MIT, reproduced here.

```
Copyright (c) 2016-2019 Boaz Segev
```

## http (Rust crate)

`lib/HttpTypes` is a Julia port of the Rust [`http`](https://github.com/hyperium/http)
crate, version 1.5.0, including its tests. Licence: MIT or Apache-2.0, at your
option; full texts in `lib/HttpTypes/LICENSE-MIT` and `lib/HttpTypes/LICENSE-APACHE`.

```
Copyright (c) 2017 http-rs authors
```
