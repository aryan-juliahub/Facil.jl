r = http(ex, "GET", "/whoami")
@test r.status == 200
@test occursin(r"^you are 127\.0\.0\.1, port \d+\n$", r.body)
# A client that gives up after a second: the handler notices and stops.
run(ignorestatus(`curl -s --max-time 1 $(base_url(ex))/report`))
@test wait_until(() -> http(ex, "GET", "/cancelled").body == "1 report(s) cancelled\n"; timeout = 5)
# One that waits gets the report.
@test http(ex, "GET", "/report").body == "report ready\n"
