# needs: URIs
r = http(ex, "GET", "/caf%C3%A9/menu?name=Ada%20L&n=2")
@test r.status == 200
@test r.body == "hello Ada L\nhello Ada L\nsegments: café, menu\n"
@test http(ex, "GET", "/").body == "hello world\nsegments: \n"
@test http(ex, "GET", "/?n=99").status == 400
@test http(ex, "GET", "/?n=abc").body == "hello world\nsegments: \n"
