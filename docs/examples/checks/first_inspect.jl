r = http(ex, "POST", "/orders/17?expand=items"; headers = ["User-Agent" => "curl/8.7.1"], body = """{"qty": 2}""")
@test r.status == 200
@test r.body == """
method: POST
path:   /orders/17
query:  expand=items
agent:  curl/8.7.1
body:   10 bytes
"""
@test r.headers["x-served-by"] == "facil"
@test r.headers["content-type"] == "text/plain; charset=utf-8"
@test r.headers["content-length"] == "89"
r = http(ex, "GET", "/")
@test occursin("query:  (none)", r.body)
@test occursin("agent:  (none)", r.body)
@test occursin("body:   0 bytes", r.body)
