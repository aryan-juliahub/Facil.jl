# mode: process
# The example is itself a test file: it runs its test sets and exits.
@test wait_until(() -> process_exited(ex.proc); timeout = 120)
@test ex.proc.exitcode == 0
out() = parentmodule(typeof(ex)).output(ex)
@test wait_until(() -> occursin(r"handler\s+\|\s+7\s+7", out()))
@test wait_until(() -> occursin(r"server\s+\|\s+6\s+6", out()))
