# Response compression: gzip through libdeflate (zlib-ng for long streams),
# zstd, brotli. Whole bodies are compressed in the handler's task (see
# CompressHandler), streams by the task that writes them; never by Julia's
# bundled zlib.

using libdeflate_jll: libdeflate
using Zstd_jll: libzstd
using brotli_jll: libbrotlienc, libbrotlidec
using ZlibNG_jll: libzng

const ENCODING_NAMES = (gzip = "gzip", br = "br", zstd = "zstd")
const DEFAULT_LEVELS = (gzip = 6, br = 4, zstd = 3)

function encoding_symbol(x)
    (x === nothing || x === false) && return :none
    x === true && return :auto
    s = Symbol(x)
    s in (:gz, :gzip) && return :gzip
    s in (:br, :brotli) && return :br
    s in (:zstd, :auto, :none) && return s
    throw(ArgumentError("unknown compression $(repr(x)); use :gzip, :br, :zstd, :auto or nothing"))
end

default_level(enc::Symbol) = enc === :gzip ? DEFAULT_LEVELS.gzip : enc === :br ? DEFAULT_LEVELS.br : DEFAULT_LEVELS.zstd

# ---- whole-buffer codecs ----

const LD_POOL = Dict{Int,Vector{Ptr{Cvoid}}}()
const ZSTD_POOL = Ptr{Cvoid}[]
const CODEC_LOCK = Threads.SpinLock()

function ld_take(level::Int)
    lock(CODEC_LOCK)
    v = get!(Vector{Ptr{Cvoid}}, LD_POOL, level)
    c = isempty(v) ? C_NULL : pop!(v)
    unlock(CODEC_LOCK)
    c != C_NULL && return c
    c = @ccall libdeflate.libdeflate_alloc_compressor(level::Cint)::Ptr{Cvoid}
    c == C_NULL && throw(ArgumentError("libdeflate: invalid level $level"))
    c
end
ld_give(level::Int, c::Ptr{Cvoid}) = (lock(CODEC_LOCK); push!(LD_POOL[level], c); unlock(CODEC_LOCK); nothing)

function zstd_take()
    lock(CODEC_LOCK)
    c = isempty(ZSTD_POOL) ? C_NULL : pop!(ZSTD_POOL)
    unlock(CODEC_LOCK)
    c != C_NULL && return c
    c = @ccall libzstd.ZSTD_createCCtx()::Ptr{Cvoid}
    c == C_NULL && throw(OutOfMemoryError())
    c
end
zstd_give(c::Ptr{Cvoid}) = (lock(CODEC_LOCK); push!(ZSTD_POOL, c); unlock(CODEC_LOCK); nothing)
zstd_failed(n::Csize_t) = (@ccall libzstd.ZSTD_isError(n::Csize_t)::Cuint) != 0
zstd_error(n::Csize_t) = error("zstd: ", unsafe_string(@ccall libzstd.ZSTD_getErrorName(n::Csize_t)::Cstring))

@inline bytes_of(data::Union{String,Vector{UInt8}}) = data
@inline bytes_of(data::AbstractString) = String(data)
@inline bytes_of(data::AbstractVector{UInt8}) = Vector{UInt8}(data)

# Compresses into a scratch buffer of the worst-case size, then copies out the
# exact result so the response does not keep the scratch capacity alive.
function compress_with(f, data, bound::Int)
    src = bytes_of(data)
    scratch = Vector{UInt8}(undef, bound)
    n = GC.@preserve src scratch f(pointer(src), sizeof(src), pointer(scratch), bound)
    out = Vector{UInt8}(undef, n)
    copyto!(out, 1, scratch, 1, n)
    out
end

"""
    Facil.gzip(data; level = 6) -> Vector{UInt8}

Compress `data` (a `String` or byte vector) as one gzip member (RFC 1952) with
libdeflate. `level` is 1 (fastest) to 12 (smallest). This is what
`compress = true` uses for whole bodies; call it yourself to precompress a
response you cache.

# Examples
```jldoctest
julia> using Facil

julia> z = Facil.gzip("hello "^1000);

julia> length(z) < 100
true

julia> z[1:2] == [0x1f, 0x8b]
true
```
"""
function gzip(data; level::Integer = DEFAULT_LEVELS.gzip)
    lv = Int(level)
    c = ld_take(lv)
    try
        n = sizeof(data)
        bound = Int(@ccall libdeflate.libdeflate_gzip_compress_bound(c::Ptr{Cvoid}, n::Csize_t)::Csize_t)
        compress_with(data, bound) do s, len, d, cap
            Int(@gcsafe_ccall libdeflate.libdeflate_gzip_compress(c::Ptr{Cvoid}, s::Ptr{UInt8}, len::Csize_t, d::Ptr{UInt8}, cap::Csize_t)::Csize_t)
        end
    finally
        ld_give(lv, c)
    end
end

"""
    Facil.zstd(data; level = 3) -> Vector{UInt8}

Compress `data` (a `String` or byte vector) as one Zstandard frame (RFC 8878).
`level` is -7 to 22; higher is smaller and slower.

# Examples
```jldoctest
julia> using Facil

julia> length(Facil.zstd("hello "^1000)) < 100
true
```
"""
function zstd(data; level::Integer = DEFAULT_LEVELS.zstd)
    c = zstd_take()
    try
        bound = Int(@ccall libzstd.ZSTD_compressBound(sizeof(data)::Csize_t)::Csize_t)
        compress_with(data, bound) do s, len, d, cap
            r = @gcsafe_ccall libzstd.ZSTD_compressCCtx(c::Ptr{Cvoid}, d::Ptr{UInt8}, cap::Csize_t, s::Ptr{UInt8}, len::Csize_t, Cint(level)::Cint)::Csize_t
            zstd_failed(r) && zstd_error(r)
            Int(r)
        end
    finally
        zstd_give(c)
    end
end

"""
    Facil.brotli(data; level = 4) -> Vector{UInt8}

Compress `data` (a `String` or byte vector) with Brotli (RFC 7932). `level` is
the quality, 0 to 11; the window is 4 MiB (2²² bytes).

# Examples
```jldoctest
julia> using Facil

julia> length(Facil.brotli("hello "^1000)) < 100
true
```
"""
function brotli(data; level::Integer = DEFAULT_LEVELS.br)
    bound = Int(@ccall libbrotlienc.BrotliEncoderMaxCompressedSize(sizeof(data)::Csize_t)::Csize_t)
    bound = max(bound, sizeof(data) + 1024)
    compress_with(data, bound) do s, len, d, cap
        out = Ref{Csize_t}(cap)
        ok = @gcsafe_ccall libbrotlienc.BrotliEncoderCompress(Cint(level)::Cint, 22::Cint, 0::Cint, len::Csize_t, s::Ptr{UInt8},
                                                               out::Ptr{Csize_t}, d::Ptr{UInt8})::Cint
        ok == 1 || error("brotli: compression failed")
        Int(out[])
    end
end

compress_body(enc::Symbol, data, level::Int) =
    enc === :gzip ? gzip(data; level) : enc === :br ? brotli(data; level) : zstd(data; level)

# ---- decoders (tests and clients) ----

"Decompresses gzip data, including several concatenated members."
function gunzip(data::AbstractVector{UInt8})
    src = Vector{UInt8}(data)
    d = @ccall libdeflate.libdeflate_alloc_decompressor()::Ptr{Cvoid}
    out = UInt8[]
    try
        pos = 0
        while pos < length(src)
            cap = max(4 * (length(src) - pos), 1 << 16)
            while true
                buf = Vector{UInt8}(undef, cap)
                inn, got = Ref{Csize_t}(0), Ref{Csize_t}(0)
                r = GC.@preserve src buf @ccall libdeflate.libdeflate_gzip_decompress_ex(d::Ptr{Cvoid}, (pointer(src) + pos)::Ptr{UInt8},
                        (length(src) - pos)::Csize_t, buf::Ptr{UInt8}, cap::Csize_t, inn::Ptr{Csize_t}, got::Ptr{Csize_t})::Cint
                if r == 3
                    cap *= 4
                    continue
                end
                r == 0 || error("gunzip: libdeflate error $r")
                append!(out, view(buf, 1:Int(got[])))
                pos += Int(inn[])
                break
            end
        end
    finally
        @ccall libdeflate.libdeflate_free_decompressor(d::Ptr{Cvoid})::Cvoid
    end
    out
end

struct ZBuf
    ptr::Ptr{UInt8}
    size::Csize_t
    pos::Csize_t
end

"Decompresses zstd data (one or more frames)."
function unzstd(data::AbstractVector{UInt8})
    src = Vector{UInt8}(data)
    d = @ccall libzstd.ZSTD_createDCtx()::Ptr{Cvoid}
    out = UInt8[]
    buf = Vector{UInt8}(undef, 1 << 16)
    try
        GC.@preserve src buf begin
            inb = Ref(ZBuf(pointer(src), length(src), 0))
            while true
                outb = Ref(ZBuf(pointer(buf), length(buf), 0))
                r = @ccall libzstd.ZSTD_decompressStream(d::Ptr{Cvoid}, outb::Ptr{ZBuf}, inb::Ptr{ZBuf})::Csize_t
                zstd_failed(r) && zstd_error(r)
                append!(out, view(buf, 1:Int(outb[].pos)))
                inb[].pos == inb[].size && outb[].pos < length(buf) && break
            end
        end
    finally
        @ccall libzstd.ZSTD_freeDCtx(d::Ptr{Cvoid})::Csize_t
    end
    out
end

# brotli_jll's decoder rejects valid streams on aarch64 Linux (its own binary
# does, also when called from C), so it is checked once before it is trusted.
const BROTLI_SAMPLE = (hex2bytes("1b03010004d4c3ebed7d97b211ca2c068ce6d8042a5f9f15"), "hello brotli "^20)
const BROTLI_DECODER = Ref{Ptr{Cvoid}}(C_NULL)
const BROTLI_DECODER_LOCK = ReentrantLock()

function brotli_decoder()
    BROTLI_DECODER[] == C_NULL || return BROTLI_DECODER[]
    lock(BROTLI_DECODER_LOCK) do
        BROTLI_DECODER[] == C_NULL || return BROTLI_DECODER[]
        h = Libdl.dlopen(libbrotlidec)
        ok = try
            String(brotli_decode(h, BROTLI_SAMPLE[1])) == BROTLI_SAMPLE[2]
        catch
            false
        end
        ok || error("unbrotli: the brotli decoder of brotli_jll rejects valid input on this platform; Facil's brotli compression is not affected")
        BROTLI_DECODER[] = h
    end
end

function brotli_decode(lib::Ptr{Cvoid}, src::Vector{UInt8})
    create, run, destroy = Libdl.dlsym(lib, :BrotliDecoderCreateInstance), Libdl.dlsym(lib, :BrotliDecoderDecompressStream),
                           Libdl.dlsym(lib, :BrotliDecoderDestroyInstance)
    s = ccall(create, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}), C_NULL, C_NULL, C_NULL)
    out = UInt8[]
    buf = Vector{UInt8}(undef, 1 << 16)
    try
        GC.@preserve src buf begin
            avail_in, next_in = Ref{Csize_t}(length(src)), Ref{Ptr{UInt8}}(pointer(src))
            while true
                avail_out, next_out = Ref{Csize_t}(length(buf)), Ref{Ptr{UInt8}}(pointer(buf))
                r = ccall(run, Cint, (Ptr{Cvoid}, Ptr{Csize_t}, Ptr{Ptr{UInt8}}, Ptr{Csize_t}, Ptr{Ptr{UInt8}}, Ptr{Csize_t}),
                          s, avail_in, next_in, avail_out, next_out, C_NULL)
                append!(out, view(buf, 1:length(buf)-Int(avail_out[])))
                r == 1 && break
                r == 3 && continue
                error("unbrotli: corrupt or truncated input (state $r)")
            end
        end
    finally
        ccall(destroy, Cvoid, (Ptr{Cvoid},), s)
    end
    out
end

"Whether [`unbrotli`](@ref) has a decoder that works on this machine."
brotli_decoder_works() = try
    brotli_decoder() != C_NULL
catch
    false
end

"Decompresses brotli data."
unbrotli(data::AbstractVector{UInt8}) = brotli_decode(brotli_decoder(), Vector{UInt8}(data))

# ---- streaming encoders ----

const GZIP_SEGMENT = 128 * 1024

mutable struct ZNGStream
    next_in::Ptr{UInt8}
    avail_in::UInt32
    total_in::Csize_t
    next_out::Ptr{UInt8}
    avail_out::UInt32
    total_out::Csize_t
    msg::Ptr{UInt8}
    state::Ptr{Cvoid}
    zalloc::Ptr{Cvoid}
    zfree::Ptr{Cvoid}
    opaque::Ptr{Cvoid}
    data_type::Cint
    adler::UInt32
    reserved::Culong
end
ZNGStream() = ZNGStream(C_NULL, 0, 0, C_NULL, 0, 0, C_NULL, C_NULL, C_NULL, C_NULL, C_NULL, 0, 0, 0)

const Z_NO_FLUSH, Z_SYNC_FLUSH, Z_FINISH = Cint(0), Cint(2), Cint(4)
const ZNG_POOL = Dict{Int,Vector{ZNGStream}}()

function zng_take(level::Int)
    lock(CODEC_LOCK)
    v = get!(Vector{ZNGStream}, ZNG_POOL, level)
    z = isempty(v) ? nothing : pop!(v)
    unlock(CODEC_LOCK)
    if z === nothing
        z = ZNGStream()
        r = @ccall libzng.zng_deflateInit2(z::Ref{ZNGStream}, Cint(level)::Cint, 8::Cint, 31::Cint, 8::Cint, 0::Cint)::Cint
        r == 0 || error("zlib-ng: deflateInit2 failed ($r)")
    else
        @ccall libzng.zng_deflateReset(z::Ref{ZNGStream})::Cint
    end
    z
end
zng_give(level::Int, z::ZNGStream) = (lock(CODEC_LOCK); push!(ZNG_POOL[level], z); unlock(CODEC_LOCK); nothing)

# A gzip stream is one gzip member. Input is held until GZIP_SEGMENT bytes, a
# flush or the end: a stream that ends first is compressed in one go by
# libdeflate; otherwise zlib-ng (sync flushes) takes over from there.
mutable struct GzipEncoder
    const level::Int
    const buf::Vector{UInt8}
    z::Union{Nothing,ZNGStream}
    const out::Vector{UInt8}
end
GzipEncoder(level::Int) = GzipEncoder(level, UInt8[], nothing, Vector{UInt8}(undef, 64 * 1024))

function zng_run!(out::F, e::GzipEncoder, p::Ptr{UInt8}, n::Int, flush::Cint) where {F}
    z = e.z::ZNGStream
    z.next_in = p
    z.avail_in = n
    GC.@preserve e while true
        z.next_out = pointer(e.out)
        z.avail_out = length(e.out)
        r = @gcsafe_ccall libzng.zng_deflate(z::Ref{ZNGStream}, flush::Cint)::Cint
        (r == 0 || r == 1 || r == -5) || error("zlib-ng: deflate failed ($r)")
        k = length(e.out) - Int(z.avail_out)
        k > 0 && out(e.out[1:k])
        r == 1 && break
        (z.avail_out != 0 && z.avail_in == 0) && break
    end
    nothing
end

function gzip_switch!(out::F, e::GzipEncoder, flush::Cint) where {F}
    e.z = zng_take(min(e.level, 9))
    GC.@preserve e zng_run!(out, e, pointer(e.buf), length(e.buf), flush)
    empty!(e.buf)
    nothing
end

function encode!(out::F, e::GzipEncoder, p::Ptr{UInt8}, n::Int) where {F}
    if e.z !== nothing
        zng_run!(out, e, p, n, Z_NO_FLUSH)
        return nothing
    end
    k = length(e.buf)
    resize!(e.buf, k + n)
    GC.@preserve e unsafe_copyto!(pointer(e.buf, k + 1), p, n)
    length(e.buf) >= GZIP_SEGMENT && gzip_switch!(out, e, Z_NO_FLUSH)
    nothing
end

function encode_flush!(out::F, e::GzipEncoder) where {F}
    if e.z === nothing
        isempty(e.buf) || gzip_switch!(out, e, Z_SYNC_FLUSH)
    else
        zng_run!(out, e, Ptr{UInt8}(C_NULL), 0, Z_SYNC_FLUSH)
    end
    nothing
end

function encode_finish!(out::F, e::GzipEncoder) where {F}
    if e.z === nothing
        out(gzip(e.buf; level = e.level))
        empty!(e.buf)
    else
        zng_run!(out, e, Ptr{UInt8}(C_NULL), 0, Z_FINISH)
    end
    nothing
end

function encoder_free!(e::GzipEncoder)
    z = e.z
    z === nothing && return
    e.z = nothing
    zng_give(min(e.level, 9), z)
end

const ZSTD_E_CONTINUE, ZSTD_E_FLUSH, ZSTD_E_END = Cint(0), Cint(1), Cint(2)

mutable struct ZstdEncoder
    ctx::Ptr{Cvoid}
    const out::Vector{UInt8}
end

function ZstdEncoder(level::Int)
    c = zstd_take()
    @ccall libzstd.ZSTD_CCtx_reset(c::Ptr{Cvoid}, 1::Cint)::Csize_t
    r = @ccall libzstd.ZSTD_CCtx_setParameter(c::Ptr{Cvoid}, 100::Cint, Cint(level)::Cint)::Csize_t
    zstd_failed(r) && (zstd_give(c); zstd_error(r))
    ZstdEncoder(c, Vector{UInt8}(undef, 64 * 1024))
end

function zstd_run!(out::F, e::ZstdEncoder, p::Ptr{UInt8}, n::Int, op::Cint) where {F}
    inb = Ref(ZBuf(p, n, 0))
    GC.@preserve e while true
        outb = Ref(ZBuf(pointer(e.out), length(e.out), 0))
        r = @gcsafe_ccall libzstd.ZSTD_compressStream2(e.ctx::Ptr{Cvoid}, outb::Ptr{ZBuf}, inb::Ptr{ZBuf}, op::Cint)::Csize_t
        zstd_failed(r) && zstd_error(r)
        k = Int(outb[].pos)
        k > 0 && out(e.out[1:k])
        done = op == ZSTD_E_CONTINUE ? inb[].pos == inb[].size : r == 0
        done && break
    end
    nothing
end
encode!(out::F, e::ZstdEncoder, p::Ptr{UInt8}, n::Int) where {F} = zstd_run!(out, e, p, n, ZSTD_E_CONTINUE)
encode_flush!(out::F, e::ZstdEncoder) where {F} = zstd_run!(out, e, Ptr{UInt8}(C_NULL), 0, ZSTD_E_FLUSH)
encode_finish!(out::F, e::ZstdEncoder) where {F} = zstd_run!(out, e, Ptr{UInt8}(C_NULL), 0, ZSTD_E_END)
function encoder_free!(e::ZstdEncoder)
    e.ctx == C_NULL && return
    @ccall libzstd.ZSTD_CCtx_reset(e.ctx::Ptr{Cvoid}, 3::Cint)::Csize_t
    zstd_give(e.ctx)
    e.ctx = C_NULL
end

const BROTLI_PROCESS, BROTLI_FLUSH, BROTLI_FINISH = Cint(0), Cint(1), Cint(2)

mutable struct BrotliEncoder
    st::Ptr{Cvoid}
    const out::Vector{UInt8}
end

function BrotliEncoder(level::Int)
    s = @ccall libbrotlienc.BrotliEncoderCreateInstance(C_NULL::Ptr{Cvoid}, C_NULL::Ptr{Cvoid}, C_NULL::Ptr{Cvoid})::Ptr{Cvoid}
    s == C_NULL && throw(OutOfMemoryError())
    @ccall libbrotlienc.BrotliEncoderSetParameter(s::Ptr{Cvoid}, 1::Cint, UInt32(level)::UInt32)::Cint
    @ccall libbrotlienc.BrotliEncoderSetParameter(s::Ptr{Cvoid}, 2::Cint, UInt32(22)::UInt32)::Cint
    BrotliEncoder(s, Vector{UInt8}(undef, 64 * 1024))
end

function brotli_run!(out::F, e::BrotliEncoder, p::Ptr{UInt8}, n::Int, op::Cint) where {F}
    avail_in, next_in = Ref{Csize_t}(n), Ref{Ptr{UInt8}}(p)
    GC.@preserve e while true
        avail_out, next_out = Ref{Csize_t}(length(e.out)), Ref{Ptr{UInt8}}(pointer(e.out))
        ok = @gcsafe_ccall libbrotlienc.BrotliEncoderCompressStream(e.st::Ptr{Cvoid}, op::Cint, avail_in::Ptr{Csize_t}, next_in::Ptr{Ptr{UInt8}},
                avail_out::Ptr{Csize_t}, next_out::Ptr{Ptr{UInt8}}, C_NULL::Ptr{Csize_t})::Cint
        ok == 1 || error("brotli: stream compression failed")
        k = length(e.out) - Int(avail_out[])
        k > 0 && out(e.out[1:k])
        more = (@ccall libbrotlienc.BrotliEncoderHasMoreOutput(e.st::Ptr{Cvoid})::Cint) != 0
        (avail_in[] == 0 && !more) && break
    end
    nothing
end
encode!(out::F, e::BrotliEncoder, p::Ptr{UInt8}, n::Int) where {F} = brotli_run!(out, e, p, n, BROTLI_PROCESS)
encode_flush!(out::F, e::BrotliEncoder) where {F} = brotli_run!(out, e, Ptr{UInt8}(C_NULL), 0, BROTLI_FLUSH)
encode_finish!(out::F, e::BrotliEncoder) where {F} = brotli_run!(out, e, Ptr{UInt8}(C_NULL), 0, BROTLI_FINISH)
function encoder_free!(e::BrotliEncoder)
    e.st == C_NULL && return
    @ccall libbrotlienc.BrotliEncoderDestroyInstance(e.st::Ptr{Cvoid})::Cvoid
    e.st = C_NULL
end

stream_encoder(enc::Symbol, level::Int) =
    enc === :gzip ? GzipEncoder(level) : enc === :br ? BrotliEncoder(level) : ZstdEncoder(level)

# ---- negotiation ----

"""
    CompressOptions(; prefer = (:zstd, :br, :gzip), gzip = 6, br = 4, zstd = 3,
                    min_size = 1024, compressible = Facil.compressible_type)

How a server compresses responses. Pass it as the `compress` keyword of
[`serve!`](@ref); `compress = true` is `CompressOptions()`.

# Keywords
- `prefer`: the encodings the server offers, most wanted first, from `:zstd`,
  `:br` and `:gzip`. Among the encodings the client accepts with the highest
  q-value in `Accept-Encoding`, the one listed first here is used. Leave one
  out to never use it.
- `gzip::Integer = 6` (1 to 12), `br::Integer = 4` (0 to 11),
  `zstd::Integer = 3` (-7 to 22): the level for each encoding.
- `min_size::Integer = 1024`: whole bodies smaller than this many bytes are
  sent as they are.
- `compressible = Facil.compressible_type`: a function
  `content_type::String -> Bool` that says which content types to compress;
  see [`Facil.compressible_type`](@ref).

# Throws
- `ArgumentError` for an unknown encoding in `prefer`, a level out of range or
  a negative `min_size`.

# What is and is not compressed
A response is sent as it is when any of these holds: the client sent no
`Accept-Encoding` or accepts none of `prefer`; the body is under `min_size`;
the response already has a `content-encoding`; it has
`cache-control: no-transform`; its status is 1xx, 204, 206 or 304; its content
type is not compressible; or compressing did not make it smaller.
[`sendfile`](@ref) responses and event streams are never compressed.
A [`stream`](@ref) left at `compress = :auto` is compressed as it is written.

Whenever the content type is compressible Facil adds `vary: accept-encoding`,
so caches keep the variants apart.

Compression runs where the handler runs: on a worker task, or on the reactor
thread for an inline handler, where a large body delays other connections.

# Examples
```jldoctest
julia> using Facil

julia> import Downloads

julia> opts = CompressOptions(; prefer = (:gzip,), min_size = 100);

julia> server = serve!(req -> "hello "^1000, 0; compress = opts);

julia> r = Downloads.request("http://127.0.0.1:\$(port(server))/"; output = devnull, headers = ["Accept-Encoding" => "gzip"]);

julia> Dict(r.headers)["content-encoding"]
"gzip"

julia> close(server)
```

See the [compression guide](@ref compression-guide).
"""
struct CompressOptions
    prefer::Vector{Symbol}
    gzip::Int
    br::Int
    zstd::Int
    min_size::Int
    compressible::Any
end

function CompressOptions(; prefer = (:zstd, :br, :gzip), gzip::Integer = DEFAULT_LEVELS.gzip, br::Integer = DEFAULT_LEVELS.br,
                         zstd::Integer = DEFAULT_LEVELS.zstd, min_size::Integer = 1024, compressible = compressible_type)
    p = Symbol[encoding_symbol(x) for x in prefer]
    all(in((:gzip, :br, :zstd)), p) || throw(ArgumentError("prefer may list only :gzip, :br and :zstd"))
    1 <= gzip <= 12 || throw(ArgumentError("gzip level must be 1–12"))
    0 <= br <= 11 || throw(ArgumentError("br level must be 0–11"))
    -7 <= zstd <= 22 || throw(ArgumentError("zstd level must be -7–22"))
    min_size >= 0 || throw(ArgumentError("min_size must not be negative"))
    CompressOptions(p, gzip, br, zstd, min_size, compressible)
end

compress_options(x::Bool) = x ? CompressOptions() : nothing
compress_options(::Nothing) = nothing
compress_options(x::CompressOptions) = x
compress_options(x) = throw(ArgumentError("compress must be true, false or a CompressOptions"))

level_of(o::CompressOptions, enc::Symbol) = enc === :gzip ? o.gzip : enc === :br ? o.br : o.zstd

const COMPRESSIBLE_APP = ("json", "javascript", "ecmascript", "xml", "wasm", "x-ndjson", "graphql",
                          "x-www-form-urlencoded", "rtf", "x-sh", "x-yaml", "yaml", "toml", "sql")

"""
    Facil.compressible_type(content_type) -> Bool

The default test [`CompressOptions`](@ref) uses to decide whether a response
of this `content-type` is worth compressing. Parameters (`; charset=...`) are
ignored.

`true` for `text/*`, any `+json` or `+xml` type, `image/svg+xml`, TrueType and
OpenType fonts, and `application/` json, javascript, xml, wasm, x-ndjson,
graphql, x-www-form-urlencoded, yaml, toml, sql and a few more. `false` for
formats that are already compressed (images, video, archives, WOFF fonts).

# Examples
```jldoctest
julia> using Facil

julia> Facil.compressible_type("application/json; charset=utf-8")
true

julia> Facil.compressible_type("image/png")
false

julia> mine(ct) = Facil.compressible_type(ct) || ct == "application/x-custom";

julia> CompressOptions(; compressible = mine) isa CompressOptions
true
```
"""
function compressible_type(ct::AbstractString)
    t = lowercase(strip(first(split(ct, ';'))))
    startswith(t, "text/") && return true
    (endswith(t, "+json") || endswith(t, "+xml")) && return true
    t == "image/svg+xml" && return true
    (t == "font/ttf" || t == "font/otf" || t == "application/vnd.ms-fontobject") && return true
    startswith(t, "application/") && return t[13:end] in COMPRESSIBLE_APP
    false
end

# Parses Accept-Encoding; picks the highest q, ties broken by `prefer` order.
function negotiate(ae::AbstractString, prefer::Vector{Symbol})
    best, bestq = :none, 0.0
    star = -1.0
    qs = (gzip = -1.0, br = -1.0, zstd = -1.0)
    for part in eachsplit(ae, ',')
        item = strip(part)
        isempty(item) && continue
        name, q = item, 1.0
        i = findfirst(';', item)
        if i !== nothing
            name = rstrip(item[1:prevind(item, i)])
            for p in eachsplit(item[nextind(item, i):end], ';')
                kv = strip(p)
                if length(kv) > 2 && (kv[1] == 'q' || kv[1] == 'Q') && kv[2] == '='
                    v = tryparse(Float64, kv[3:end])
                    q = v === nothing ? 0.0 : clamp(v, 0.0, 1.0)
                end
            end
        end
        n = lowercase(name)
        if n == "gzip" || n == "x-gzip"
            qs = merge(qs, (gzip = q,))
        elseif n == "br"
            qs = merge(qs, (br = q,))
        elseif n == "zstd"
            qs = merge(qs, (zstd = q,))
        elseif n == "*"
            star = q
        end
    end
    for enc in prefer
        q = getfield(qs, enc)
        q < 0 && (q = star)
        if q > bestq
            best, bestq = enc, q
        end
    end
    best
end

const VARY_VALUE = "accept-encoding"

function add_vary!(hs::HeaderMap)
    for v in get_all(hs, header.VARY)
        s = lowercase(as_str(v))
        (occursin("accept-encoding", s) || strip(s) == "*") && return
    end
    append!(hs, header.VARY, VARY_VALUE)
    nothing
end

function content_type_of(hs::HeaderMap, body)
    ct = get(hs, header.CONTENT_TYPE, nothing)
    ct === nothing || return as_str(ct)
    body isa AbstractString ? TEXT_PLAIN : body isa AbstractVector{UInt8} ? OCTET_STREAM : ""
end

# Shared checks for whole bodies and streams: the encoding to use (or :none)
# and whether the response may vary by Accept-Encoding at all.
function choose_encoding(req, res::Response, o::CompressOptions, ct::AbstractString)
    st = Int(UInt16(res.status))
    (st < 200 || st == 204 || st == 206 || st == 304) && return :none, false
    hs = res.headers
    haskey(hs, header.CONTENT_ENCODING) && return :none, false
    cc = get(hs, header.CACHE_CONTROL, nothing)
    (cc !== nothing && occursin("no-transform", lowercase(as_str(cc)))) && return :none, false
    (isempty(ct) || !o.compressible(ct)) && return :none, false
    ae = get(headers(req), header.ACCEPT_ENCODING, nothing)
    ae === nothing && return :none, true
    negotiate(as_str(ae), o.prefer), true
end

"""
    Facil.compress_response(req, res, opts::CompressOptions)

Apply `opts` to one handler result, as a server started with
`serve!(...; compress = opts)` does for every result.

Returns a new [`Response`](@ref) with a compressed body and `content-encoding`
when `res` qualifies (see [`CompressOptions`](@ref)), a [`stream`](@ref)
response with its encoding chosen, or `res` itself. Call it in a handler to
compress only some routes on a server started without `compress`.

# Examples
```jldoctest
julia> using Facil

julia> req = Request(Methods.GET, "/"; headers = ["accept-encoding" => "gzip"]);

julia> res = Facil.compress_response(req, Response(StatusCodes.OK, "hello "^1000), CompressOptions());

julia> String(headers(res)["content-encoding"])
"gzip"

julia> sizeof(body(res)) < 100
true
```
"""
compress_response(req, res, ::CompressOptions) = res
compress_response(req, res::AbstractString, o::CompressOptions) =
    compress_response(req, Response(StatusCodes.OK, String(res); headers = [header.CONTENT_TYPE => TEXT_PLAIN]), o)

function compress_response(req, res::Response{T}, o::CompressOptions) where {T<:Union{String,Vector{UInt8},SubString{String}}}
    b = res.body
    (sizeof(b) < o.min_size || bodyless(Int(UInt16(res.status)))) && return res
    ct = content_type_of(res.headers, b)
    enc, varies = choose_encoding(req, res, o, ct)
    varies && add_vary!(res.headers)
    enc === :none && return res
    z = compress_body(enc, b, level_of(o, enc))
    length(z) >= sizeof(b) && return res
    hs = res.headers
    haskey(hs, header.CONTENT_TYPE) || (hs[header.CONTENT_TYPE] = ct)
    hs[header.CONTENT_ENCODING] = getfield(ENCODING_NAMES, enc)
    Response{Vector{UInt8}}(res.status, res.version, hs, res.extensions, z)
end

"""
A server handler wrapped by `serve!(...; compress)`; runs where the handler runs
(its task, or the reactor for inline handlers), so compression does too.
"""
struct CompressHandler{F}
    f::F
    opts::CompressOptions
end
(c::CompressHandler)(req) = compress_response(req, c.f(req), c.opts)

wrap_handler(f, ::Nothing) = f
wrap_handler(f, o::CompressOptions) = CompressHandler(f, o)
