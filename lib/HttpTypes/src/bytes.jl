const StrLike = Union{String,SubString{String}}
const DenseBytes = Union{Vector{UInt8},Base.CodeUnits{UInt8,String},
    SubArray{UInt8,1,Vector{UInt8},Tuple{UnitRange{Int}},true}}
const BytesLike = Union{StrLike,DenseBytes}

@inline _nbytes(x::StrLike) = sizeof(x)
@inline _nbytes(x::DenseBytes) = length(x)
@inline _ptr(x::BytesLike) = pointer(x)
@inline _ptr(x::Base.CodeUnits{UInt8,String}) = pointer(x.s)

@inline _load(p::Ptr{UInt8}, i::Int) = unsafe_load(p, i)

@inline _memeq(p::Ptr{UInt8}, s::String, n::Int) =
    ccall(:memcmp, Cint, (Ptr{UInt8}, Ptr{UInt8}, Csize_t), p, pointer(s), n) == 0

# RFC 9110 `tchar`, 1-based by byte value.
const TCHAR = let t = zeros(UInt8, 256)
    for c in "!#\$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
        t[UInt8(c)+1] = UInt8(c)
    end
    t
end
