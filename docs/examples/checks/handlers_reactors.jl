# mode: process
tasks = [Threads.@spawn http(ex, "GET", "/") for _ in 1:40]
@test all(t -> fetch(t).body == "hello from a reactor thread", tasks)
