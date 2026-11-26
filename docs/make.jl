using Documenter
using Markdown
using Facil
using HttpTypes

const DRAFT = "--draft" in ARGS

include(joinpath(@__DIR__, "examples", "run.jl"))

const EXAMPLES = joinpath(@__DIR__, "examples")
const SNIPPET = r"^\s*#= (snippet: [\w-]+|end) =#\s*$"

"""
    example(file)
    example(file, snippet)

The source of `docs/examples/file` as a code block, for `@eval` blocks in the
pages. With `snippet`, only the lines between `#= snippet: name =#` and the next
`#= end =#`; the marker lines themselves are never shown.
"""
function example(file::AbstractString, snippet::Union{Nothing,AbstractString} = nothing)
    lines = readlines(joinpath(EXAMPLES, file))
    if snippet !== nothing
        a = findfirst(l -> occursin(Regex("^\\s*#= snippet: $snippet =#\\s*\$"), l), lines)
        a === nothing && error("no snippet $snippet in $file")
        b = findnext(l -> occursin(r"^\s*#= end =#\s*$", l), lines, a)
        b === nothing && error("snippet $snippet in $file has no end")
        lines = lines[a+1:b-1]
        indent = minimum(l -> something(findfirst(!isspace, l), typemax(Int)) - 1, filter(!isempty, lines); init = 0)
        lines = [isempty(l) ? l : l[indent+1:end] for l in lines]
    end
    code = join(filter(l -> !occursin(SNIPPET, l), lines), "\n")
    Markdown.MD(Markdown.Code("julia", rstrip(code)))
end

if !("--skip-examples" in ARGS) && !DRAFT
    DocExamples.run_all()
end

DocMeta.setdocmeta!(HttpTypes, :DocTestSetup, :(using HttpTypes); recursive = true)
DocMeta.setdocmeta!(Facil, :DocTestSetup, :(using Facil; import Downloads); recursive = true)

# In a draft build pages that are not written yet are left out of the navigation.
existing(p::Pair) = p.second isa String ? (isfile(joinpath(@__DIR__, "src", p.second)) ? p : nothing) :
    (kids = filter(!isnothing, map(existing, p.second)); isempty(kids) ? nothing : p.first => kids)
const PAGES = let pages = include(joinpath(@__DIR__, "pages.jl"))
    DRAFT ? filter(!isnothing, map(existing, pages)) : pages
end

makedocs(;
    sitename = "Facil.jl",
    authors = "Facil.jl contributors",
    modules = [Facil, HttpTypes],
    checkdocs = :exports,
    warnonly = DRAFT,
    doctest = !("--skip-doctests" in ARGS),
    repo = Remotes.GitHub("aryan-juliahub", "Facil.jl"),
    format = Documenter.HTML(;
        prettyurls = get(ENV, "CI", nothing) == "true",
        canonical = "https://aryan-juliahub.github.io/Facil.jl",
        edit_link = "main",
        assets = ["assets/facil.css"],
        size_threshold = 600_000,
        size_threshold_warn = 400_000,
        search_size_threshold_warn = 2 * 2^20,
        collapselevel = 2,
    ),
    pages = PAGES,
)

if get(ENV, "CI", nothing) == "true"
    deploydocs(; repo = "github.com/aryan-juliahub/Facil.jl.git", devbranch = "main", push_preview = false)
end
