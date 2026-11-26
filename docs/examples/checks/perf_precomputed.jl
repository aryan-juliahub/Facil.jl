tasks = [Threads.@spawn http(ex, "GET", "/") for _ in 1:50]
rs = fetch.(tasks)
@test all(r -> r.status == 200 && r.body == example.INDEX, rs)
@test rs[1].headers["content-type"] == "text/html; charset=utf-8"
@test rs[1].headers["cache-control"] == "max-age=60"
@test http(ex, "GET", "/x").body == "not found\n"
@test wait_until(() -> Facil.pinned_bodies() == 0)
