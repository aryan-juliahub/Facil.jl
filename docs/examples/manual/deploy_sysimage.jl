# Build a system image that already contains Facil, your packages and the
# compiled code of your routes:  julia --project=. deploy_sysimage.jl
using PackageCompiler

create_sysimage([:Facil];
                sysimage_path = "app_sysimage.so",
                precompile_execution_file = joinpath(@__DIR__, "deploy_warm.jl"))
