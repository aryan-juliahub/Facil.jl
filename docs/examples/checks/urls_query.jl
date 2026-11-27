r = http(ex, "GET", "/caf%C3%A9/menu?name=Ada+L&tag=a&tag=b%26c")
@test r.status == 200
@test r.body == "path: /café/menu\nhello Ada L\ntags: a, b&c\n"
@test http(ex, "GET", "/").body == "path: /\nhello world\ntags: \n"
@test http(ex, "GET", "/a+b?name=%zz").body == "path: /a+b\nhello %zz\ntags: \n"
r = http(ex, "GET", "/files/a%2Fb")
@test r.status == 400 && r.body == "bad path\n"
@test http(ex, "GET", "/bad%FF").status == 400
