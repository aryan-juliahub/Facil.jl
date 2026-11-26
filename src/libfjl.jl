const UNSUPPORTED_OS = "Facil.jl requires Linux or macOS (facil.io has no Windows support); on Windows use WSL2. HttpTypes.jl works on Windows."
Sys.iswindows() && error(UNSUPPORTED_OS)

const LIBNAME = "libfacil_julia." * Libdl.dlext
const FACIL_UUID = Base.PkgId(@__MODULE__).uuid
const LOCAL_LIB = joinpath(dirname(@__DIR__), "deps", "usr", "lib", LIBNAME)
const SCRATCH_LIB = joinpath(Scratch.scratch_path(FACIL_UUID, "libfacil_julia"), "lib", LIBNAME)
const HAVE_JLL = Base.identify_package(@__MODULE__, "facil_julia_jll") !== nothing

@static if HAVE_JLL
    import facil_julia_jll
end

# The build script, included here so that it loads its packages as Facil's own.
module LocalBuild
include(joinpath(dirname(@__DIR__), "deps", "build_local.jl"))
end

# facil_julia_jll's library, or nothing on a platform it has no binary for.
function jll_library()
    @static if HAVE_JLL
        facil_julia_jll.is_available() && return facil_julia_jll.libfacil_julia
    end
    nothing
end

# Resolved once per precompile: the `libfacil_path` preference; with
# facil_julia_jll, an existing local build and then the JLL's library;
# otherwise a local build, compiled now unless it is up to date.
function resolve_libfjl()
    pref = @load_preference("libfacil_path", nothing)
    pref === nothing || return String(pref)
    if HAVE_JLL && get(ENV, "FACIL_JL_LOCAL_BUILD", "") != "1"
        for f in (LOCAL_LIB, SCRATCH_LIB)
            isfile(f) && return f
        end
        jll = jll_library()
        jll === nothing || return jll
    end
    LocalBuild.build()
end

const LIBFJL = resolve_libfjl()
LIBFJL isa AbstractString && isfile(LIBFJL) && include_dependency(LIBFJL)
foreach(include_dependency, LocalBuild.build_inputs())
const FJL_ABI = 2

const libfjl_handle = Ref{Ptr{Cvoid}}(C_NULL)

libfjl_missing() = LIBFJL isa AbstractString && isabspath(LIBFJL) && !isfile(LIBFJL)

function load_libfjl()
    Sys.iswindows() && error(UNSUPPORTED_OS)
    build = joinpath(dirname(@__DIR__), "deps", "build_local.jl")
    libfjl_missing() && error("Facil: $(LIBFJL) is missing; build it with `julia --project=$(dirname(@__DIR__)) $build`, or set the `libfacil_path` preference")
    libfjl_handle[] = Libdl.dlopen(LIBFJL, Libdl.RTLD_NOW | Libdl.RTLD_GLOBAL)
    abi = @ccall LIBFJL.fjl_abi()::Cint
    abi == FJL_ABI || error("Facil: $(LIBFJL) has ABI $abi, expected $FJL_ABI; rebuild with $build")
    n = @ccall LIBFJL.fjl_sizeof_listen_s()::Csize_t
    n == sizeof(ListenOptions) || error("Facil: fjl_listen_s is $n bytes in C, $(sizeof(ListenOptions)) in Julia")
    nothing
end

# A ccall that may block runs GC-safe, so a collection never waits on it.
macro gcsafe_ccall(expr)
    if VERSION >= v"1.12.0-"
        return esc(:(@ccall gc_safe = true $expr))
    end
    # The exported jl_gc_safe_enter/leave act on the current thread and take no
    # ptls. Arguments are converted first: Julia code must not run GC-safe.
    (Meta.isexpr(expr, :(::)) && Meta.isexpr(expr.args[1], :call)) || error("@gcsafe_ccall: expected f(args...)::T")
    call, rettype = expr.args
    pre = Expr[]
    args = map(call.args[2:end]) do a
        Meta.isexpr(a, :(::)) || error("@gcsafe_ccall: every argument needs a type")
        c = gensym("arg")
        push!(pre, :(local $c = Base.cconvert($(a.args[2]), $(a.args[1]))))
        :($c::$(a.args[2]))
    end
    quote
        $(pre...)
        local state = ccall(:jl_gc_safe_enter, Int8, ())
        local r = @ccall $(Expr(:(::), Expr(:call, call.args[1], args...), rettype))
        ccall(:jl_gc_safe_leave, Cvoid, (Int8,), state)
        r
    end |> esc
end

fjl_version() = unsafe_string(@ccall LIBFJL.fjl_version()::Cstring)
fjl_build_id() = unsafe_string(@ccall LIBFJL.fjl_build_id()::Cstring)

function fjl_start(threads::Integer)
    n = Cint(threads)
    @gcsafe_ccall LIBFJL.fjl_start(n::Cint)::Cint
end

"""
Mirror of `fjl_call_s`: completion record for a call that finishes on another thread.
"""
mutable struct FjlCall
    result::Int
    err::Cint
    done::Cint
    notify::Ptr{Cvoid}
    notify_arg::Ptr{Cvoid}
end

"""
    await_call(start) -> Union{FjlCall,Nothing}

Calls `start(ptr::Ptr{FjlCall})::Cint`; when it returns 0, yields until the C side
completes the call (through `uv_async_send`). Returns `nothing` if `start` failed.
An exception thrown into the waiting task is rethrown once the call is complete.
"""
function await_call(start)
    cond = Base.AsyncCondition()
    call = FjlCall(-1, 0, 0, cglobal(:uv_async_send), cond.handle)
    interrupted = nothing
    try
        GC.@preserve call cond begin
            start(Ptr{FjlCall}(pointer_from_objref(call))) == 0 || return nothing
            # C writes to `call` and signals `cond` when it completes, so an
            # exception thrown into the wait is held until then.
            while true
                try
                    wait(cond)
                    break
                catch e
                    interrupted === nothing && (interrupted = e)
                    call.done != 0 && break
                end
            end
        end
    finally
        Base.close(cond)
    end
    interrupted === nothing || throw(interrupted)
    call
end

# For exit hooks, where the calling task may not be able to wait.
fjl_stop_blocking() = @gcsafe_ccall LIBFJL.fjl_stop()::Cint

function fjl_stop()
    call = await_call(p -> @ccall LIBFJL.fjl_stop_async(p::Ptr{FjlCall})::Cint)
    call === nothing ? Cint(-1) : Cint(call.result)
end
fjl_is_running() = (@ccall LIBFJL.fjl_is_running()::Cint) != 0
fjl_on_reactor() = (@ccall LIBFJL.fjl_on_reactor()::Cint) != 0
fjl_reactor_threads() = Int(@ccall LIBFJL.fjl_reactor_threads()::Cint)

fjl_post(run::Ptr{Cvoid}, cancel::Ptr{Cvoid}, a::Ptr{Cvoid}, b::Ptr{Cvoid}=C_NULL, c::Ptr{Cvoid}=C_NULL) =
    @ccall LIBFJL.fjl_post(run::Ptr{Cvoid}, cancel::Ptr{Cvoid}, a::Ptr{Cvoid}, b::Ptr{Cvoid}, c::Ptr{Cvoid})::Cint
fjl_wake() = @ccall LIBFJL.fjl_wake()::Cvoid
fjl_resume(handle::Ptr{Cvoid}, task::Ptr{Cvoid}, fallback::Ptr{Cvoid}) =
    @ccall LIBFJL.fjl_resume(handle::Ptr{Cvoid}, task::Ptr{Cvoid}, fallback::Ptr{Cvoid})::Cint

"""
Mirror of `fjl_listen_s`; zero fields take facil.io's defaults.
"""
struct ListenOptions
    on_request::Ptr{Cvoid}
    on_upgrade::Ptr{Cvoid}
    on_finish::Ptr{Cvoid}
    udata::Ptr{Cvoid}
    public_folder::Ptr{UInt8}
    max_header_size::Csize_t
    max_body_size::Csize_t
    max_clients::Int
    tls::Ptr{Cvoid}
    ws_max_msg_size::Csize_t
    timeout::UInt8
    ws_timeout::UInt8
    log::UInt8
    public_folder_flags::UInt8
end

ListenOptions(on_request::Ptr{Cvoid}; on_upgrade=C_NULL, on_finish=C_NULL, udata=C_NULL,
              public_folder=C_NULL, max_header_size=0, max_body_size=0, max_clients=0,
              tls=C_NULL, ws_max_msg_size=0, timeout=0, ws_timeout=0, log=false,
              public_folder_flags=0) =
    ListenOptions(on_request, on_upgrade, on_finish, udata, public_folder, max_header_size,
                  max_body_size, max_clients, tls, ws_max_msg_size, timeout, ws_timeout, log,
                  public_folder_flags)

"""
    fjl_listen(address, port, opts) -> Int

Opens an HTTP listener on the reactor and returns its uuid; yields while waiting.
Any `public_folder` pointer in `opts` must stay valid for the duration of the call.
"""
function fjl_listen(address::Union{Nothing,AbstractString}, port::Union{Integer,AbstractString}, opts::ListenOptions)
    a = address === nothing ? nothing : String(address)
    p = string(port)
    if (a !== nothing && occursin('\0', a)) || occursin('\0', p)
        throw(ArgumentError("address and port must not contain NUL"))
    end
    r = Ref(opts)
    call = GC.@preserve a p r begin
        ap = a === nothing ? Ptr{UInt8}(C_NULL) : pointer(a)
        pp = pointer(p)
        rp = Base.unsafe_convert(Ptr{ListenOptions}, r)
        await_call(c -> @ccall LIBFJL.fjl_listen_async(ap::Ptr{UInt8}, pp::Ptr{UInt8}, rp::Ptr{ListenOptions}, c::Ptr{FjlCall})::Cint)
    end
    call === nothing && error("Facil: the reactor is not running")
    call.result == -1 && throw(SystemError("fjl_listen($(repr(address)), $(repr(p)))", Int(call.err)))
    call.result
end

fjl_listen_close(uuid::Integer) = @ccall LIBFJL.fjl_listen_close(uuid::Int)::Cint
fjl_settings_udata(settings::Ptr{Cvoid}) = @ccall LIBFJL.fjl_settings_udata(settings::Ptr{Cvoid})::Ptr{Cvoid}
fjl_server_udata(h::Ptr{Cvoid}) = @ccall LIBFJL.fjl_server_udata(h::Ptr{Cvoid})::Ptr{Cvoid}

const STAT_NAMES = (:wakes, :drains, :tasks_run, :tasks_cancelled, :pool_threads, :starts)

function fjl_stats()
    out = zeros(UInt64, length(STAT_NAMES))
    @ccall LIBFJL.fjl_stats(out::Ptr{UInt64})::Cvoid
    NamedTuple{STAT_NAMES}(Tuple(Int.(out)))
end

fjl_log_level(level::Integer) = Int(@ccall LIBFJL.fjl_log_level(Cint(level)::Cint)::Cint)
fjl_sig_disposition(sig::Integer) = Int(@ccall LIBFJL.fjl_sig_disposition(Cint(sig)::Cint)::Cint)
fjl_thread_stack_size() = Int(@ccall LIBFJL.fjl_thread_stack_size()::Csize_t)
