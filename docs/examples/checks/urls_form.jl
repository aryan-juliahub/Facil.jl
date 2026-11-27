form = ["Content-Type" => "application/x-www-form-urlencoded"]
r = http(ex, "POST", "/signup"; headers = form, body = "user=Ada+Lovelace&role=admin&role=dev%26ops")
@test r.status == 200
@test r.body == "welcome Ada Lovelace\nroles: admin, dev&ops\n"
@test http(ex, "POST", "/signup"; headers = form, body = "role=x").status == 400
@test http(ex, "POST", "/signup"; headers = ["Content-Type" => "application/json"], body = "{}").status == 415
r = http(ex, "GET", "/signup")
@test r.status == 405 && r.headers["allow"] == "POST"
out = curl("-s", "$(base_url(ex))/signup", "--data-urlencode", "user=Zoë & co", "-d", "role=a")
@test out == "welcome Zoë & co\nroles: a\n"
