# needs: JSON
# The example is itself a test file: its @testset ran when it was loaded.
@test isdefined(example, :call)
@test isempty(example.NOTES)
