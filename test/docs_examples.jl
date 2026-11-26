# Runs the programs shown in the documentation (docs/examples) against a client.
# Examples that need packages outside the test environment (JSON, URIs) are
# skipped here; the documentation build runs them all.
module DocsExamplesTests

include(joinpath(@__DIR__, "..", "docs", "examples", "run.jl"))

DocExamples.run_all(; strict = false)

end
