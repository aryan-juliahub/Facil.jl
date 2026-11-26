tasks = [Threads.@spawn http(ex, "GET", "/"; headers = ["x-client" => "c$(i % 5)"]) for i in 1:200]
bodies = [fetch(t).body for t in tasks]
@test sort(bodies) == sort(["request $n" for n in 1:200])
@test example.HITS[] == 200
@test sort(collect(keys(example.LAST_SEEN))) == ["c0", "c1", "c2", "c3", "c4"]
@test http(ex, "GET", "/").body == "request 201"
